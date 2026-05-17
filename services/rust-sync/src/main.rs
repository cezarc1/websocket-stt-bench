//! Canonical synchronous Rust STT gateway — **evented**, not
//! thread-per-connection. A single `mio` (epoll) event loop drives every
//! WebSocket and every inference socket; no async runtime, no
//! per-connection thread. Connection state is a cheap heap object, one
//! loop multiplexes thousands of fds, an in-flight inference POST never
//! blocks the loop (its socket is just another fd in the same poll), and
//! flush deadlines live in one heap — so cost scales with *work*, not
//! with connection count.

mod config;
mod http;
mod inference;
mod protocol;
mod session;

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap};
use std::io;
use std::net::{SocketAddr, TcpListener as StdListener, ToSocketAddrs};
use std::time::{Duration, Instant};

use mio::net::TcpListener;
use mio::{Events, Interest, Poll, Token};
use socket2::{Domain, Socket, Type};

use crate::config::{Config, LISTEN_BACKLOG};
use crate::session::{Conn, Outcome, decode_token, ws_token};

const LISTENER: Token = Token(0);
const IDLE_CAP: Duration = Duration::from_secs(1);

/// `(deadline, conn id)`, min-heap via `Reverse`. Exactly one live entry
/// per connection: pushed on accept, re-pushed each time its timer is
/// serviced. A stale entry (deadline moved later because inference
/// finished) just causes one cheap no-op `on_timer` pop — self-correcting.
type Timers = BinaryHeap<Reverse<(Instant, usize)>>;

fn main() -> io::Result<()> {
    let config = Config::from_env();
    let inference_addr = resolve(&config);
    let mut listener = bind_listener(config.port)?;

    eprintln!(
        "{{\"runtime\":\"rust-sync\",\"model\":\"evented (mio epoll, no async runtime)\",\"port\":{},\"inference\":\"{}\",\"flush_interval_ms\":{}}}",
        config.port,
        inference_addr,
        config.flush_interval.as_millis()
    );

    let mut poll = Poll::new()?;
    poll.registry()
        .register(&mut listener, LISTENER, Interest::READABLE)?;
    let mut events = Events::with_capacity(1024);
    let mut conns: HashMap<usize, Conn> = HashMap::new();
    let mut timers: Timers = BinaryHeap::new();
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
            let token = event.token();
            if token == LISTENER {
                accept(
                    &listener,
                    &mut conns,
                    &mut timers,
                    &mut next_id,
                    &poll,
                    inference_addr,
                    &config,
                );
                continue;
            }
            let (id, is_inf) = decode_token(token);
            let Some(conn) = conns.get_mut(&id) else {
                continue;
            };
            let reg = poll.registry();
            let outcome = if is_inf {
                conn.on_inference(reg, event.is_writable(), &config)
            } else if event.is_writable() {
                conn.on_writable(reg, &config)
            } else {
                conn.on_readable(reg, &config)
            };
            if matches!(outcome, Outcome::Close) {
                closing.push(id);
            }
        }

        // Service only the connections whose deadline actually elapsed —
        // O(due + log N), not O(N). Re-push each serviced connection's
        // next deadline so it stays in the heap exactly once.
        while let Some(&Reverse((t, id))) = timers.peek() {
            if t > now {
                break;
            }
            timers.pop();
            if let Some(conn) = conns.get_mut(&id) {
                if matches!(conn.on_timer(poll.registry(), now, &config), Outcome::Close) {
                    closing.push(id);
                } else {
                    timers.push(Reverse((conn.deadline(), id)));
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

#[allow(clippy::too_many_arguments)]
fn accept(
    listener: &TcpListener,
    conns: &mut HashMap<usize, Conn>,
    timers: &mut Timers,
    next_id: &mut usize,
    poll: &Poll,
    inference_addr: SocketAddr,
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
                let conn = Conn::new(id, stream, inference_addr, config);
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
