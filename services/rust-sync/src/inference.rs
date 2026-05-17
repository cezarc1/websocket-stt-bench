//! Bounded **shared** pool of non-blocking HTTP/1.1 inference
//! connections, driven on a **dedicated OS thread** — *not* the
//! WebSocket event loop.
//!
//! This is the deliberate architecture mirror of the C++23 gateway,
//! which runs uWebSockets on its loop thread and libcurl-multi on a
//! separate `std::jthread`. Here: the WS loop (thread A) hands batches
//! over an `mpsc` channel; this module's [`run`] (thread B) owns its own
//! `mio::Poll` and the [`InferencePool`], drives the HTTP/1.1 state
//! machines, and routes results back over a second channel, waking
//! thread A's poll via a [`mio::Waker`]. No async runtime, zero new
//! dependencies — `std::thread` + `std::sync::mpsc` + `mio::Waker` is
//! the canonical Rust spelling of C++'s queue + condvar + multi-wakeup.
//!
//! One socket per *in-flight request* (default 512, like rust-axum's
//! reqwest pool) — NOT one per gateway connection. The one-inflight
//! invariant stays structural on thread A (its per-`Conn` `pending`
//! gate); this thread just executes submit/abort/drive.

use std::io::{self, Read, Write};
use std::net::SocketAddr;
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};

use mio::net::TcpStream;
use mio::{Events, Interest, Poll, Registry, Token, Waker};

use crate::config::Config;
use crate::protocol::{ErrorKind, ErrorStage, InferResponse};

/// Thread A → thread B. One per due flush (or abort).
pub enum Cmd {
    /// A batch is ready; run one inference for `owner`.
    Submit {
        owner: usize,
        body: Vec<u8>,
        cpu_passes: u32,
    },
    /// `owner` timed out or its WS closed on thread A; drop any in-flight
    /// slot it holds so the socket/keep-alive is reclaimed.
    Abort { owner: usize },
}

/// Thread B → thread A. Delivered to the owning `Conn::deliver`.
pub type Done = (usize, Result<InferResponse, InferError>);

const B_WAKE: Token = Token(0);

/// Pool sockets occupy `Token(slot + 1)`; `Token(0)` ([`B_WAKE`]) is the
/// cross-thread wake. `pool_slot` is the exact inverse — they must change
/// together, so they live together.
fn pool_token(slot: usize) -> Token {
    Token(slot + 1)
}

fn pool_slot(token: Token) -> usize {
    token.0 - 1
}

pub struct InferError {
    pub stage: ErrorStage,
    pub kind: ErrorKind,
    pub message: String,
    pub status: Option<u16>,
    pub retryable: bool,
    pub elapsed_ms: f64,
}

/// The three transport-level failures (timeout, reset, abandoned dial)
/// share everything but `kind`/`message`/`elapsed_ms`: an
/// `InferenceRequest`-stage, retryable, status-less error.
fn transport_error(kind: ErrorKind, message: String, elapsed_ms: f64) -> InferError {
    InferError {
        stage: ErrorStage::InferenceRequest,
        kind,
        message,
        status: None,
        retryable: true,
        elapsed_ms,
    }
}

/// A connection on thread A timed out its in-flight request. The error is
/// built loop-side (it is derived from elapsed wall time, not the socket)
/// so thread A never has to round-trip thread B to emit the partial.
pub fn timeout_error(elapsed_ms: f64) -> InferError {
    transport_error(
        ErrorKind::Timeout,
        "inference timed out".to_owned(),
        elapsed_ms,
    )
}

enum State {
    Disconnected,
    Connecting,
    Idle,
    Sending { off: usize },
    Receiving,
}

struct Slot {
    sock: Option<TcpStream>,
    state: State,
    owner: Option<usize>,
    req: Vec<u8>,
    resp: Vec<u8>,
    started: Instant,
    retried: bool,
    dialed: bool,
    registered: bool,
}

impl Slot {
    fn new() -> Self {
        Self {
            sock: None,
            state: State::Disconnected,
            owner: None,
            req: Vec::with_capacity(64 * crate::config::FRAME_BYTES),
            resp: Vec::with_capacity(512),
            started: Instant::now(),
            retried: false,
            dialed: false,
            registered: false,
        }
    }

    fn ensure_registered(&mut self, reg: &Registry, token: Token, interest: Interest) {
        let fresh = std::mem::take(&mut self.dialed);
        let Some(sock) = self.sock.as_mut() else {
            self.registered = false;
            return;
        };
        if fresh || !self.registered {
            let _ = reg.register(sock, token, interest);
            self.registered = true;
        } else {
            let _ = reg.reregister(sock, token, interest);
        }
    }

    fn deregister(&mut self, reg: &Registry) {
        if let Some(sock) = self.sock.as_mut() {
            let _ = reg.deregister(sock);
        }
        self.registered = false;
    }

    fn build(&mut self, config: &Config, body: &[u8], cpu_passes: u32) {
        self.started = Instant::now();
        self.retried = false;
        self.resp.clear();
        self.req.clear();
        let _ = write!(
            self.req,
            "POST {} HTTP/1.1\r\nHost: {}\r\nx-cpu-passes: {}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
            config.inference_path,
            config.inference_host,
            cpu_passes,
            body.len()
        );
        self.req.extend_from_slice(body);
    }

    fn dial(&mut self, addr: SocketAddr) -> io::Result<()> {
        let s = TcpStream::connect(addr)?;
        let _ = s.set_nodelay(true);
        self.sock = Some(s);
        self.state = State::Connecting;
        self.dialed = true;
        Ok(())
    }

    fn drive(&mut self, writable: bool) -> Step {
        match self.run(writable) {
            Ok(step) => step,
            Err(e) => self.retry_or_fail(e),
        }
    }

    fn run(&mut self, writable: bool) -> io::Result<Step> {
        loop {
            match self.state {
                State::Connecting => {
                    let s = self.sock.as_mut().expect("sock");
                    if let Some(err) = s.take_error()? {
                        return Err(err);
                    }
                    if s.peer_addr().is_err() {
                        return Ok(Step::Pending {
                            want_writable: true,
                        });
                    }
                    self.state = State::Sending { off: 0 };
                }
                State::Sending { mut off } => {
                    let s = self.sock.as_mut().expect("sock");
                    while off < self.req.len() {
                        match s.write(&self.req[off..]) {
                            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                            Ok(n) => off += n,
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                                self.state = State::Sending { off };
                                return Ok(Step::Pending {
                                    want_writable: true,
                                });
                            }
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(e) => return Err(e),
                        }
                    }
                    self.state = State::Receiving;
                }
                State::Receiving => {
                    let s = self.sock.as_mut().expect("sock");
                    let mut chunk = [0u8; 4096];
                    loop {
                        match s.read(&mut chunk) {
                            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                            Ok(n) => self.resp.extend_from_slice(&chunk[..n]),
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(e) => return Err(e),
                        }
                    }
                    match parse_response(&self.resp) {
                        Some(result) => {
                            self.state = State::Idle;
                            let started = self.started;
                            return Ok(Step::Done(result.map_err(|(stage, kind, msg, status)| {
                                InferError {
                                    stage,
                                    kind,
                                    message: msg,
                                    status,
                                    retryable: kind_retryable(kind),
                                    elapsed_ms: started.elapsed().as_secs_f64() * 1000.0,
                                }
                            })));
                        }
                        None => {
                            return Ok(Step::Pending {
                                want_writable: false,
                            });
                        }
                    }
                }
                State::Idle => {
                    if !writable {
                        let s = self.sock.as_mut().expect("sock");
                        let mut probe = [0u8; 1];
                        if matches!(s.read(&mut probe), Ok(0)) {
                            self.sock = None;
                            self.state = State::Disconnected;
                        }
                    }
                    return Ok(Step::Pending {
                        want_writable: false,
                    });
                }
                State::Disconnected => {
                    return Ok(Step::Pending {
                        want_writable: false,
                    });
                }
            }
        }
    }

    fn retry_or_fail(&mut self, e: io::Error) -> Step {
        if !self.retried && self.sock.is_some() {
            self.retried = true;
            self.state = State::Sending { off: 0 };
            self.sock = None;
            return Step::Redial;
        }
        self.sock = None;
        self.state = State::Disconnected;
        Step::Done(Err(transport_error(
            ErrorKind::ConnectionReset,
            e.to_string(),
            self.started.elapsed().as_secs_f64() * 1000.0,
        )))
    }
}

enum Step {
    Pending {
        want_writable: bool,
    },
    /// Stale keep-alive socket; the pool must redial and resend.
    Redial,
    Done(Result<InferResponse, InferError>),
}

struct InferencePool {
    addr: SocketAddr,
    slots: Vec<Slot>,
    free: Vec<usize>,
}

impl InferencePool {
    fn new(addr: SocketAddr, size: usize) -> Self {
        let mut slots = Vec::with_capacity(size);
        let mut free = Vec::with_capacity(size);
        for i in 0..size {
            slots.push(Slot::new());
            free.push(size - 1 - i);
        }
        Self { addr, slots, free }
    }

    /// At least one request is mid-flight. Derived from the free-list so
    /// there is no separate counter to keep in sync.
    fn has_inflight(&self) -> bool {
        self.free.len() != self.slots.len()
    }

    /// Take a free slot for `owner`, build + start its request. When the
    /// pool is exhausted the request is reported as a retryable reset so
    /// thread A emits an `error` frame and clears `pending` (the buffer
    /// then keeps growing — back-pressure as oldest-frame latency).
    fn submit(
        &mut self,
        owner: usize,
        body: &[u8],
        cpu_passes: u32,
        config: &Config,
        reg: &Registry,
    ) -> Option<Done> {
        let Some(idx) = self.free.pop() else {
            return Some((owner, Err(reset_error())));
        };
        let slot = &mut self.slots[idx];
        slot.owner = Some(owner);
        slot.build(config, body, cpu_passes);
        if slot.sock.is_some() {
            slot.state = State::Sending { off: 0 };
        } else if slot.dial(self.addr).is_err() {
            slot.owner = None;
            self.free.push(idx);
            return Some((owner, Err(reset_error())));
        }
        slot.ensure_registered(reg, pool_token(idx), Interest::WRITABLE);
        None
    }

    /// Drive a slot on its readiness event. `Some(done)` when the request
    /// completed; the slot is recycled for the next borrower.
    fn on_event(&mut self, idx: usize, writable: bool, reg: &Registry) -> Option<Done> {
        let slot = &mut self.slots[idx];
        match slot.drive(writable) {
            Step::Pending { want_writable } => {
                let interest = if want_writable {
                    Interest::WRITABLE
                } else {
                    Interest::READABLE
                };
                slot.ensure_registered(reg, pool_token(idx), interest);
                None
            }
            Step::Redial => {
                if slot.dial(self.addr).is_err() {
                    let owner = slot.owner.take();
                    self.recycle(idx, reg);
                    return owner.map(|o| (o, Err(reset_error())));
                }
                slot.ensure_registered(reg, pool_token(idx), Interest::WRITABLE);
                None
            }
            Step::Done(result) => {
                let owner = slot.owner.take();
                self.recycle(idx, reg);
                owner.map(|o| (o, result))
            }
        }
    }

    /// Thread A timed out / closed `owner`. Abandon whatever slot it holds
    /// (linear scan — aborts only happen on timeout/close, which are rare
    /// relative to the ~thousands-of-flushes/s happy path). No `Done` is
    /// produced: thread A already emitted the timeout/closed locally.
    fn abort_owner(&mut self, owner: usize, reg: &Registry) {
        let Some(idx) = self.slots.iter().position(|s| s.owner == Some(owner)) else {
            return;
        };
        let slot = &mut self.slots[idx];
        slot.owner = None;
        slot.sock = None;
        slot.state = State::Disconnected;
        self.recycle(idx, reg);
    }

    /// Slot finished or was abandoned: keep its keep-alive socket (if any)
    /// registered readable so a server close is noticed, and make it
    /// available again.
    fn recycle(&mut self, idx: usize, reg: &Registry) {
        let slot = &mut self.slots[idx];
        slot.owner = None;
        if slot.sock.is_some() {
            slot.ensure_registered(reg, pool_token(idx), Interest::READABLE);
        } else {
            slot.deregister(reg);
        }
        self.free.push(idx);
    }
}

/// Thread A's handle to the inference thread. Pairs the command channel
/// with the [`mio::Waker`] bound to thread B's poll, so every enqueue
/// also unparks B — the Rust spelling of C++'s queue push +
/// `curl_multi_wakeup()`. Called from the WS loop; never blocks (the
/// channel is unbounded and the per-`Conn` one-inflight gate already
/// bounds outstanding work to ≤ the connection count).
pub struct InferHandle {
    tx: Sender<Cmd>,
    b_waker: Waker,
}

impl InferHandle {
    pub fn submit(&self, owner: usize, body: Vec<u8>, cpu_passes: u32) {
        let _ = self.tx.send(Cmd::Submit {
            owner,
            body,
            cpu_passes,
        });
        let _ = self.b_waker.wake();
    }

    pub fn abort(&self, owner: usize) {
        let _ = self.tx.send(Cmd::Abort { owner });
        let _ = self.b_waker.wake();
    }
}

/// Spawn the inference thread. `a_waker` is the WS loop's own
/// [`mio::Waker`] (bound to its `RESULT_WAKER` token); thread B fires it
/// after pushing completions so the loop drains `done_rx` promptly
/// instead of on its next timer wake. Returns the WS-side handle + the
/// result receiver.
pub fn spawn(
    addr: SocketAddr,
    size: usize,
    config: Config,
    a_waker: Waker,
) -> io::Result<(InferHandle, Receiver<Done>)> {
    let (cmd_tx, cmd_rx) = std::sync::mpsc::channel::<Cmd>();
    let (done_tx, done_rx) = std::sync::mpsc::channel::<Done>();

    let poll = Poll::new()?;
    let b_waker = Waker::new(poll.registry(), B_WAKE)?;

    std::thread::Builder::new()
        .name("stt-inference".to_owned())
        .spawn(move || run(poll, addr, size, config, cmd_rx, done_tx, a_waker))?;

    Ok((
        InferHandle {
            tx: cmd_tx,
            b_waker,
        },
        done_rx,
    ))
}

/// Thread B. Owns the pool + its own epoll. Never returns. A panic in
/// either loop is a fatal, unrecoverable bug (not a handled condition):
/// if thread A dies, `done_tx.send` errors are dropped here and B parks
/// harmlessly until the process is killed — there is intentionally no
/// cross-thread supervision.
fn run(
    mut poll: Poll,
    addr: SocketAddr,
    size: usize,
    config: Config,
    cmd_rx: Receiver<Cmd>,
    done_tx: Sender<Done>,
    a_waker: Waker,
) {
    let mut events = Events::with_capacity(4096);
    let mut pool = InferencePool::new(addr, size);

    loop {
        if poll
            .poll(&mut events, compute_poll_timeout(pool.has_inflight()))
            .is_err()
        {
            continue;
        }

        let mut produced = false;

        for event in events.iter() {
            if event.token() == B_WAKE {
                continue;
            }
            if let Some(done) = pool.on_event(
                pool_slot(event.token()),
                event.is_writable(),
                poll.registry(),
            ) && done_tx.send(done).is_ok()
            {
                produced = true;
            }
        }

        // One B_WAKE coalesces N enqueues; drain them all.
        while let Ok(cmd) = cmd_rx.try_recv() {
            match cmd {
                Cmd::Submit {
                    owner,
                    body,
                    cpu_passes,
                } => {
                    if let Some(done) =
                        pool.submit(owner, &body, cpu_passes, &config, poll.registry())
                        && done_tx.send(done).is_ok()
                    {
                        produced = true;
                    }
                }
                Cmd::Abort { owner } => pool.abort_owner(owner, poll.registry()),
            }
        }

        if produced {
            let _ = a_waker.wake();
        }
    }
}

/// How long thread B parks in `poll.poll(timeout)` each iteration.
///
/// This is a direct port of the proven C++ design
/// (`services/cpp23-uwebsockets/src/inference.cpp::wait_for_work` +
/// `kActivePollTimeoutMs = 10`): relying on socket-readiness wakeups
/// *alone* to advance a request's state machine can stall completions
/// for ~1 s under load when an expected wakeup for an intermediate
/// transition is never delivered (the keep-alive `State::Idle` probe,
/// the `Redial` resend, a partial-read resume — for C++ it was h2c
/// state transitions). Capping the park guarantees the state machines
/// are pumped regularly even with no readiness event.
///
/// - **Active** (≥1 request in flight): 10 ms ceiling — short enough that
///   a missed transition costs at most ~10 ms, cheap enough that the busy
///   loop is bounded.
/// - **Idle**: 1000 ms — effectively "until woken", since thread A's
///   `Cmd` enqueue fires B's [`Waker`] immediately; the bounded value is
///   only a safety net against an ever-missed wake, mirroring C++'s
///   `queue_cv_.wait_for(1000ms)`.
fn compute_poll_timeout(has_inflight: bool) -> Option<Duration> {
    Some(Duration::from_millis(if has_inflight { 10 } else { 1000 }))
}

fn reset_error() -> InferError {
    transport_error(
        ErrorKind::ConnectionReset,
        "inference connection reset".to_owned(),
        0.0,
    )
}

type ParseErr = (ErrorStage, ErrorKind, String, Option<u16>);

fn parse_response(buf: &[u8]) -> Option<Result<InferResponse, ParseErr>> {
    let head_end = buf.windows(4).position(|w| w == b"\r\n\r\n")? + 4;
    let head = std::str::from_utf8(&buf[..head_end]).ok()?;
    let mut lines = head.split("\r\n");
    let status: u16 = lines
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    let content_len: usize = lines
        .clone()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.trim()
                .eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse().ok())?
        })
        .unwrap_or(0);
    if buf.len() < head_end + content_len {
        return None;
    }
    let body = &buf[head_end..head_end + content_len];
    if !(200..300).contains(&status) {
        let (kind, _) = classify_status(status);
        return Some(Err((
            ErrorStage::InferenceRequest,
            kind,
            format!("inference returned status {status}"),
            Some(status),
        )));
    }
    match serde_json::from_slice::<InferResponse>(body) {
        Ok(infer) => Some(Ok(infer)),
        Err(e) => Some(Err((
            ErrorStage::InferenceResponseParse,
            ErrorKind::ParseError,
            e.to_string(),
            Some(status),
        ))),
    }
}

fn classify_status(status: u16) -> (ErrorKind, bool) {
    if status == 429 {
        (ErrorKind::Http429, true)
    } else if (500..600).contains(&status) {
        (ErrorKind::Http5xx, true)
    } else {
        (ErrorKind::Http5xx, false)
    }
}

fn kind_retryable(kind: ErrorKind) -> bool {
    !matches!(kind, ErrorKind::ParseError)
}
