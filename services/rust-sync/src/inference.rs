//! Bounded **shared** pool of non-blocking HTTP/1.1 inference
//! connections, owned by the event loop.
//!
//! One socket per *in-flight request* (default 512, like rust-axum's
//! reqwest pool) — NOT one per gateway connection. Opening a socket per
//! session put ~N inference fds in the single epoll loop; at thousands of
//! sessions that fd fan-out, not the inference server (measured ~1% CPU)
//! or our own CPU (~66%), was the latency wall. A gateway connection
//! borrows a free pooled socket for its single in-flight request and
//! returns it on completion, so the one-inflight-per-connection invariant
//! still holds and the loop's fd count stays bounded.

use std::io::{self, Read, Write};
use std::net::SocketAddr;
use std::time::Instant;

use mio::net::TcpStream;
use mio::{Interest, Registry, Token};

use crate::config::Config;
use crate::protocol::{ErrorKind, ErrorStage, InferResponse};

pub struct InferError {
    pub stage: ErrorStage,
    pub kind: ErrorKind,
    pub message: String,
    pub status: Option<u16>,
    pub retryable: bool,
    pub elapsed_ms: f64,
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

    fn build(&mut self, config: &Config, body: &[u8]) {
        self.started = Instant::now();
        self.retried = false;
        self.resp.clear();
        self.req.clear();
        let _ = write!(
            self.req,
            "POST {} HTTP/1.1\r\nHost: {}\r\nx-cpu-passes: {}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
            config.inference_path,
            config.inference_host,
            config.cpu_passes,
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
        Step::Done(Err(InferError {
            stage: ErrorStage::InferenceRequest,
            kind: ErrorKind::ConnectionReset,
            message: e.to_string(),
            status: None,
            retryable: true,
            elapsed_ms: self.started.elapsed().as_secs_f64() * 1000.0,
        }))
    }

    fn timeout_error(&self) -> InferError {
        InferError {
            stage: ErrorStage::InferenceRequest,
            kind: ErrorKind::Timeout,
            message: "inference timed out".to_owned(),
            status: None,
            retryable: true,
            elapsed_ms: self.started.elapsed().as_secs_f64() * 1000.0,
        }
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

pub struct InferencePool {
    addr: SocketAddr,
    slots: Vec<Slot>,
    free: Vec<usize>,
}

impl InferencePool {
    pub fn new(addr: SocketAddr, size: usize) -> Self {
        let mut slots = Vec::with_capacity(size);
        let mut free = Vec::with_capacity(size);
        for i in 0..size {
            slots.push(Slot::new());
            free.push(size - 1 - i);
        }
        Self { addr, slots, free }
    }

    /// Take a free slot for `owner`, build + start its request. Returns
    /// the slot index, or `None` when the pool is exhausted (the caller
    /// keeps its buffer — back-pressure as growing oldest-frame latency).
    pub fn submit(
        &mut self,
        owner: usize,
        body: &[u8],
        config: &Config,
        reg: &Registry,
        token: impl Fn(usize) -> Token,
    ) -> Option<usize> {
        let idx = self.free.pop()?;
        let slot = &mut self.slots[idx];
        slot.owner = Some(owner);
        slot.build(config, body);
        if slot.sock.is_some() {
            slot.state = State::Sending { off: 0 };
        } else if slot.dial(self.addr).is_err() {
            slot.owner = None;
            self.free.push(idx);
            return None;
        }
        slot.ensure_registered(reg, token(idx), Interest::WRITABLE);
        Some(idx)
    }

    /// Drive a slot on its readiness event. `Some((owner, result))` when
    /// the request completed; the slot is recycled for the next borrower.
    pub fn on_event(
        &mut self,
        idx: usize,
        writable: bool,
        reg: &Registry,
        token: impl Fn(usize) -> Token,
    ) -> Option<(usize, Result<InferResponse, InferError>)> {
        let slot = &mut self.slots[idx];
        match slot.drive(writable) {
            Step::Pending { want_writable } => {
                let interest = if want_writable {
                    Interest::WRITABLE
                } else {
                    Interest::READABLE
                };
                slot.ensure_registered(reg, token(idx), interest);
                None
            }
            Step::Redial => {
                if slot.dial(self.addr).is_err() {
                    let owner = slot.owner.take();
                    self.recycle(idx, reg, token);
                    return owner.map(|o| (o, Err(reset_error())));
                }
                slot.ensure_registered(reg, token(idx), Interest::WRITABLE);
                None
            }
            Step::Done(result) => {
                let owner = slot.owner.take();
                self.recycle(idx, reg, token);
                owner.map(|o| (o, result))
            }
        }
    }

    /// Abandon whatever a slot is doing (the borrower timed out) and
    /// return the timeout error for its owner.
    pub fn abort(
        &mut self,
        idx: usize,
        reg: &Registry,
        token: impl Fn(usize) -> Token,
    ) -> Option<(usize, InferError)> {
        let slot = &mut self.slots[idx];
        let err = slot.timeout_error();
        let owner = slot.owner.take();
        slot.sock = None;
        slot.state = State::Disconnected;
        self.recycle(idx, reg, token);
        owner.map(|o| (o, err))
    }

    /// Slot finished or was abandoned: keep its keep-alive socket (if any)
    /// registered readable so a server close is noticed, and make it
    /// available again.
    fn recycle(&mut self, idx: usize, reg: &Registry, token: impl Fn(usize) -> Token) {
        let slot = &mut self.slots[idx];
        slot.owner = None;
        if slot.sock.is_some() {
            slot.ensure_registered(reg, token(idx), Interest::READABLE);
        } else {
            slot.deregister(reg);
        }
        self.free.push(idx);
    }
}

fn reset_error() -> InferError {
    InferError {
        stage: ErrorStage::InferenceRequest,
        kind: ErrorKind::ConnectionReset,
        message: "inference connection reset".to_owned(),
        status: None,
        retryable: true,
        elapsed_ms: 0.0,
    }
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
