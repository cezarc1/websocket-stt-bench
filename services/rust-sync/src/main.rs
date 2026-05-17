//! Canonical synchronous Rust STT gateway — **evented**, not
//! thread-per-connection, and **no async runtime**. A single `mio`
//! (epoll) event loop drives every WebSocket plus a bounded shared pool
//! of inference sockets. Connection state is a cheap heap object; flush
//! deadlines live in one heap (O(log N) per wake); inference fans out
//! over a fixed pool, not one socket per session — so the loop's fd
//! count and per-event cost scale with *work*, not connection count.

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
use mio::{Events, Interest, Poll, Token};
use socket2::{Domain, Socket, Type};

use crate::config::{Config, LISTEN_BACKLOG};
use crate::inference::InferencePool;
use crate::session::{Conn, Outcome, Tick, ws_token};

const LISTENER: Token = Token(0);
/// Pool-socket tokens live above any plausible connection id so the two
/// token spaces never collide.
const POOL_BASE: usize = 1 << 40;
const IDLE_CAP: Duration = Duration::from_secs(1);

fn pool_token(slot: usize) -> Token {
    Token(POOL_BASE + slot)
}

enum Source {
    Listener,
    Ws(usize),
    Pool(usize),
}

fn decode(token: Token) -> Source {
    if token == LISTENER {
        Source::Listener
    } else if token.0 >= POOL_BASE {
        Source::Pool(token.0 - POOL_BASE)
    } else {
        Source::Ws(token.0)
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
        "{{\"runtime\":\"rust-sync\",\"model\":\"evented (mio epoll, no async runtime)\",\"port\":{},\"inference\":\"{}\",\"inference_clients\":{},\"flush_interval_ms\":{}}}",
        config.port,
        inference_addr,
        config.inference_clients,
        config.flush_interval.as_millis()
    );

    let mut poll = Poll::new()?;
    poll.registry()
        .register(&mut listener, LISTENER, Interest::READABLE)?;
    let mut events = Events::with_capacity(4096);
    let mut conns: ConnMap = ConnMap::default();
    let mut timers: Timers = BinaryHeap::new();
    let mut pool = InferencePool::new(inference_addr, config.inference_clients);
    let mut next_id: usize = 1;

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
                Source::Pool(slot) => {
                    if let Some((owner, result)) =
                        pool.on_event(slot, event.is_writable(), poll.registry(), pool_token)
                        && let Some(conn) = conns.get_mut(&owner)
                        && matches!(
                            conn.deliver(poll.registry(), result, &config),
                            Outcome::Close
                        )
                    {
                        closing.push(owner);
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
                    if let Some(slot) =
                        pool.submit(id, conn.pcm(), &config, poll.registry(), pool_token)
                    {
                        conn.begin_pending(batch, slot, now);
                    }
                    timers.push(Reverse((conn.deadline(), id)));
                }
                Tick::Timeout(slot) => {
                    if let Some((owner, err)) = pool.abort(slot, poll.registry(), pool_token)
                        && let Some(c) = conns.get_mut(&owner)
                        && matches!(
                            c.deliver(poll.registry(), Err(err), &config),
                            Outcome::Close
                        )
                    {
                        closing.push(owner);
                    }
                    if let Some(c) = conns.get_mut(&id) {
                        timers.push(Reverse((c.deadline(), id)));
                    }
                }
            }
        }

        for id in closing {
            if let Some(mut conn) = conns.remove(&id) {
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
