//! Non-blocking HTTP/1.1 inference client, one keep-alive socket per
//! connection, driven by the shared epoll loop.
//!
//! The one-inflight-per-connection invariant makes a single persistent
//! connection both correct and optimal: there is never more than one
//! request in flight on it. The socket is registered in the same `Poll`
//! as everything else, so an in-flight POST never blocks the loop — the
//! event loop keeps servicing every other connection meanwhile. This is
//! the Rust-`mio` analogue of the C++ gateway's libcurl-multi pump.

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

/// Driving the machine yields one of these each readiness event.
pub enum Step {
    /// More readiness needed; `want_writable` selects the epoll interest.
    Pending {
        want_writable: bool,
    },
    Done(Result<InferResponse, InferError>),
}

enum State {
    Disconnected,
    Connecting,
    Idle,
    Sending { off: usize },
    Receiving,
}

pub struct Inference {
    addr: SocketAddr,
    sock: Option<TcpStream>,
    state: State,
    req: Vec<u8>,
    resp: Vec<u8>,
    started: Instant,
    retried: bool,
    /// Set when a *new* socket fd is created (initial dial or redial): the
    /// next poll update must `register` (epoll has never seen the fd), not
    /// `reregister`. Kept here so the socket's whole epoll lifecycle has a
    /// single owner.
    dialed: bool,
    registered: bool,
}

impl Inference {
    pub fn new(addr: SocketAddr) -> Self {
        Self {
            addr,
            sock: None,
            state: State::Disconnected,
            req: Vec::with_capacity(64 * crate::config::FRAME_BYTES),
            resp: Vec::with_capacity(512),
            started: Instant::now(),
            retried: false,
            dialed: false,
            registered: false,
        }
    }

    /// Ensure the current inference fd is in the poll with `interest`.
    /// `register` for a fresh fd (an old one was auto-removed from epoll
    /// when its `TcpStream` dropped), `reregister` otherwise. No-op when
    /// there is no socket.
    pub fn ensure_registered(&mut self, reg: &Registry, token: Token, interest: Interest) {
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

    pub fn deregister(&mut self, reg: &Registry) {
        if let Some(sock) = self.sock.as_mut() {
            let _ = reg.deregister(sock);
        }
        self.registered = false;
    }

    pub fn started_at(&self) -> Instant {
        self.started
    }

    /// Begin a request. Builds the HTTP/1.1 frame into the reused buffer
    /// and (re)connects if the keep-alive socket is gone. Returns the
    /// epoll interest to register for the inference socket.
    pub fn start(&mut self, config: &Config, body: &[u8]) -> io::Result<bool> {
        self.started = Instant::now();
        self.retried = false;
        self.resp.clear();
        self.req.clear();
        // Write straight into the reused buffer — no transient String.
        let _ = write!(
            self.req,
            "POST {} HTTP/1.1\r\nHost: {}\r\nx-cpu-passes: {}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
            config.inference_path,
            config.inference_host,
            config.cpu_passes,
            body.len()
        );
        self.req.extend_from_slice(body);
        match self.sock {
            Some(_) => {
                self.state = State::Sending { off: 0 };
                Ok(true)
            }
            None => self.dial(),
        }
    }

    fn dial(&mut self) -> io::Result<bool> {
        let s = TcpStream::connect(self.addr)?;
        let _ = s.set_nodelay(true);
        self.sock = Some(s);
        self.state = State::Connecting;
        self.dialed = true;
        Ok(true)
    }

    /// Advance on a readiness event. `writable` is true if the socket is
    /// write-ready, false if read-ready.
    pub fn drive(&mut self, writable: bool) -> Step {
        match self.run(writable) {
            Ok(step) => step,
            Err(e) => self.maybe_retry_or_fail(e),
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
                            return Ok(Step::Done(result.map_err(|(stage, kind, msg, status)| {
                                self.error(stage, kind, msg, status, kind_retryable(kind))
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
                    // Readable while idle = the server closed keep-alive.
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

    fn maybe_retry_or_fail(&mut self, e: io::Error) -> Step {
        // A stale keep-alive socket fails on the first write/read; one
        // fresh dial+resend is the documented recovery (OxCaml-proven).
        if !self.retried {
            self.retried = true;
            self.sock = None;
            if self.dial().is_ok() {
                return Step::Pending {
                    want_writable: true,
                };
            }
        }
        self.sock = None;
        self.state = State::Disconnected;
        Step::Done(Err(self.error(
            ErrorStage::InferenceRequest,
            ErrorKind::ConnectionReset,
            e.to_string(),
            None,
            true,
        )))
    }

    /// Called by the loop when the request exceeds the time budget.
    pub fn timed_out(&mut self) -> InferError {
        self.sock = None;
        self.state = State::Disconnected;
        self.error(
            ErrorStage::InferenceRequest,
            ErrorKind::Timeout,
            "inference timed out".to_owned(),
            None,
            true,
        )
    }

    fn error(
        &self,
        stage: ErrorStage,
        kind: ErrorKind,
        message: String,
        status: Option<u16>,
        retryable: bool,
    ) -> InferError {
        InferError {
            stage,
            kind,
            message,
            status,
            retryable,
            elapsed_ms: self.started.elapsed().as_secs_f64() * 1000.0,
        }
    }
}

type ParseErr = (ErrorStage, ErrorKind, String, Option<u16>);

/// `Some(Ok)` / `Some(Err)` once the full response is buffered; `None`
/// while more body bytes are still pending.
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

/// Mirrors rust-axum: 429 and 5xx retryable; other non-2xx is `http_5xx`
/// but not retryable.
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
