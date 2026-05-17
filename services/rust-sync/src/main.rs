//! Canonical synchronous Rust STT gateway — **evented**, **no async
//! runtime**, and **two OS threads**: a `mio`/epoll WebSocket loop
//! (thread A, here) plus a dedicated inference loop (thread B,
//! [`inference`]). The split deliberately mirrors the C++23 gateway
//! (uWebSockets loop + a libcurl `std::jthread`): inference connect /
//! send / receive / JSON-parse never contends with WebSocket flushes for
//! the same core, and on the kernel scheduler a long inference burst is
//! preempted instead of stalling every connection's flush. Thread A
//! hands batches over an `mpsc` channel and is woken back via a
//! [`mio::Waker`] when results land. Connection state is a cheap heap
//! object; flush deadlines live in one heap (O(log N) per wake).

mod config;
mod http;
mod inference;
mod protocol;
mod session;

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap};
use std::hash::{BuildHasherDefault, Hasher};
use std::io;
use std::net::{SocketAddr, TcpListener as StdListener, ToSocketAddrs};
use std::time::{Duration, Instant};

use mio::net::TcpListener;
use mio::{Events, Interest, Poll, Token, Waker};
use socket2::{Domain, Socket, Type};

use crate::config::{Config, LISTEN_BACKLOG};
use crate::session::{Conn, Outcome, Tick, ws_token};

const LISTENER: Token = Token(0);
/// Thread B fires this (via a [`Waker`]) after pushing completions, so
/// the loop drains `done_rx` promptly. Connection ids start at 2 so the
/// `LISTENER`/`RESULT` tokens never collide with a `Ws(id)`.
const RESULT: Token = Token(1);
const FIRST_CONN_ID: usize = 2;
const IDLE_CAP: Duration = Duration::from_secs(1);

enum Source {
    Listener,
    Result,
    Ws(usize),
}

fn decode(token: Token) -> Source {
    match token {
        LISTENER => Source::Listener,
        RESULT => Source::Result,
        other => Source::Ws(other.0),
    }
}

type Timers = BinaryHeap<Reverse<(Instant, usize)>>;

/// Connection ids are unique small integers, so hashing them is pure
/// waste; an identity hasher removes SipHash from the per-event lookup
/// on the ~170k-events/s hot path. Zero dependencies.
#[derive(Default)]
struct IdHasher(u64);

impl Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = self.0.rotate_left(8) ^ u64::from(b);
        }
    }
    fn write_usize(&mut self, i: usize) {
        self.0 = i as u64;
    }
}

type ConnMap = HashMap<usize, Conn, BuildHasherDefault<IdHasher>>;

fn main() -> io::Result<()> {
    let config = Config::from_env();
    let inference_addr = resolve(&config);
    let mut listener = bind_listener(config.port)?;

    eprintln!(
        "{{\"runtime\":\"rust-sync\",\"model\":\"evented two-thread (ws-loop + inference-loop, no async runtime)\",\"port\":{},\"inference\":\"{}\",\"inference_clients\":{},\"flush_interval_ms\":{}}}",
        config.port,
        inference_addr,
        config.inference_clients,
        config.flush_interval.as_millis()
    );

    let mut poll = Poll::new()?;
    poll.registry()
        .register(&mut listener, LISTENER, Interest::READABLE)?;
    // Bound to RESULT on *this* poll; thread B fires it after pushing
    // completions so the loop drains `done_rx` without waiting for its
    // next timer wake.
    let a_waker = Waker::new(poll.registry(), RESULT)?;
    let (infer, done_rx) = inference::spawn(
        inference_addr,
        config.inference_clients,
        config.clone(),
        a_waker,
    )?;

    let mut events = Events::with_capacity(4096);
    let mut conns: ConnMap = ConnMap::default();
    let mut timers: Timers = BinaryHeap::new();
    let mut next_id: usize = FIRST_CONN_ID;

    loop {
        let timeout = match timers.peek() {
            Some(Reverse((t, _))) => t.saturating_duration_since(Instant::now()).min(IDLE_CAP),
            None => IDLE_CAP,
        };
        poll.poll(&mut events, Some(timeout))?;
        let now = Instant::now();
        let mut closing: Vec<usize> = Vec::new();

        for event in events.iter() {
            match decode(event.token()) {
                Source::Listener => accept(
                    &listener,
                    &mut conns,
                    &mut timers,
                    &mut next_id,
                    &poll,
                    &config,
                ),
                Source::Result => {
                    // One wake coalesces N completions; drain them all.
                    while let Ok((owner, result)) = done_rx.try_recv() {
                        if let Some(conn) = conns.get_mut(&owner)
                            && matches!(
                                conn.deliver(poll.registry(), result, &config),
                                Outcome::Close
                            )
                        {
                            closing.push(owner);
                        }
                    }
                }
                Source::Ws(id) => {
                    if let Some(conn) = conns.get_mut(&id) {
                        let reg = poll.registry();
                        let outcome = if event.is_writable() {
                            conn.on_writable(reg)
                        } else {
                            conn.on_readable(reg)
                        };
                        if matches!(outcome, Outcome::Close) {
                            closing.push(id);
                        }
                    }
                }
            }
        }

        while let Some(&Reverse((t, id))) = timers.peek() {
            if t > now {
                break;
            }
            timers.pop();
            let Some(conn) = conns.get_mut(&id) else {
                continue;
            };
            match conn.on_timer(now, &config) {
                Tick::Keep => timers.push(Reverse((conn.deadline(), id))),
                Tick::Flush(batch) => {
                    // One owned body buffer handed off per flush — the
                    // same shape as C++'s moved `body_scratch_`; `Conn`
                    // keeps its own buffer warm for the next batch.
                    infer.submit(id, conn.pcm().to_vec(), config.cpu_passes);
                    conn.begin_pending(batch, now);
                    timers.push(Reverse((conn.deadline(), id)));
                }
                Tick::Timeout(elapsed_ms) => {
                    let close = matches!(
                        conn.deliver(
                            poll.registry(),
                            Err(inference::timeout_error(elapsed_ms)),
                            &config,
                        ),
                        Outcome::Close
                    );
                    // Tell B to reclaim the slot; a late `Done` afterwards
                    // is harmless (`deliver` no-ops with no `pending`).
                    infer.abort(id);
                    if close {
                        closing.push(id);
                    } else {
                        timers.push(Reverse((conn.deadline(), id)));
                    }
                }
            }
        }

        for id in closing {
            if let Some(mut conn) = conns.remove(&id) {
                if conn.has_pending() {
                    infer.abort(id);
                }
                conn.deregister(poll.registry());
            }
        }
    }
}

fn accept(
    listener: &TcpListener,
    conns: &mut ConnMap,
    timers: &mut Timers,
    next_id: &mut usize,
    poll: &Poll,
    config: &Config,
) {
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                let _ = stream.set_nodelay(true);
                let id = *next_id;
                *next_id += 1;
                if poll
                    .registry()
                    .register(&mut stream, ws_token(id), Interest::READABLE)
                    .is_err()
                {
                    continue;
                }
                let conn = Conn::new(id, stream, config);
                timers.push(Reverse((conn.deadline(), id)));
                conns.insert(id, conn);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

fn resolve(config: &Config) -> SocketAddr {
    (config.inference_host.as_str(), config.inference_port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut it| it.next())
        .unwrap_or_else(|| panic!("cannot resolve {}", config.inference_host))
}

fn bind_listener(port: u16) -> io::Result<TcpListener> {
    let addr: SocketAddr = ([0, 0, 0, 0], port).into();
    let socket = Socket::new(Domain::IPV4, Type::STREAM, None)?;
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    socket.listen(LISTEN_BACKLOG)?;
    Ok(TcpListener::from_std(StdListener::from(socket)))
}
