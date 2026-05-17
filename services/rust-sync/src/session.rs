//! One connection's state, advanced entirely by epoll readiness — no
//! thread, no blocking. The event loop calls these handlers when the
//! connection's WebSocket socket is ready or its flush deadline elapses.
//! Inference is not a per-connection socket: a flush borrows a slot from
//! the shared [`crate::inference::InferencePool`] (owned by the loop);
//! the result is routed back here via [`Conn::deliver`].

use std::io::ErrorKind as IoErrorKind;
use std::time::Instant;

use mio::net::TcpStream;
use mio::{Interest, Registry, Token};
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::{CloseFrame, Role};
use tungstenite::{Message, WebSocket};

use crate::config::{
    Config, FRAME_BYTES, INFERENCE_TIMEOUT, REASON_BAD_FRAME_SIZE, REASON_NEED_START,
    REASON_TEXT_AFTER_START,
};
use crate::http::{self, Route};
use crate::inference::InferError;
use crate::protocol::{ERROR_TYPE, ErrorMessage, InferResponse, PARTIAL_TYPE, PartialMessage};

pub enum Outcome {
    Keep,
    Close,
}

/// What the loop must do after ticking a connection's timer.
pub enum Tick {
    Keep,
    /// Flush is due with a non-empty batch and nothing in flight — the
    /// loop should `infer.submit(..)` and then call [`Conn::begin_pending`].
    Flush(Batch),
    /// The in-flight request exceeded the budget (carries its elapsed ms).
    /// The loop emits a timeout `error` via [`Conn::deliver`] and tells
    /// the inference thread to drop the slot via `infer.abort(owner)`.
    Timeout(f64),
}

pub fn ws_token(id: usize) -> Token {
    Token(id)
}

struct FrameMeta {
    seq: u64,
    received_at: Instant,
}

/// Identity of the batch handed to inference, kept until the response.
pub struct Batch {
    oldest_seq: u64,
    newest_seq: u64,
    oldest_at: Instant,
    newest_at: Instant,
    frames: u64,
    audio_bytes: u64,
    flush_lateness_ms: f64,
}

struct Pending {
    batch: Batch,
    started: Instant,
}

pub struct Conn {
    id: usize,
    pre: Option<TcpStream>,
    hs_buf: Vec<u8>,
    ws: Option<WebSocket<TcpStream>>,
    started: bool,
    ws_writable: bool,
    pending: Option<Pending>,
    pcm: Vec<u8>,
    meta: Vec<FrameMeta>,
    json: Vec<u8>,
    seq: u64,
    next_flush: Instant,
}

impl Conn {
    pub fn new(id: usize, stream: TcpStream, config: &Config) -> Self {
        use rand::RngExt;
        let jitter_ms = config.flush_phase_jitter.as_millis() as u64;
        let phase = if jitter_ms == 0 {
            std::time::Duration::ZERO
        } else {
            std::time::Duration::from_millis(rand::rng().random_range(0..=jitter_ms))
        };
        Self {
            id,
            pre: Some(stream),
            hs_buf: Vec::with_capacity(1024),
            ws: None,
            started: false,
            ws_writable: false,
            pending: None,
            pcm: Vec::with_capacity(64 * FRAME_BYTES),
            meta: Vec::with_capacity(64),
            json: Vec::with_capacity(512),
            seq: 0,
            next_flush: Instant::now() + config.flush_interval + phase,
        }
    }

    pub fn pcm(&self) -> &[u8] {
        &self.pcm
    }

    pub fn deadline(&self) -> Instant {
        match &self.pending {
            Some(p) => (p.started + INFERENCE_TIMEOUT).min(self.next_flush),
            None => self.next_flush,
        }
    }

    /// WebSocket socket is readable (or, pre-upgrade, has request bytes).
    pub fn on_readable(&mut self, reg: &Registry) -> Outcome {
        if self.ws.is_none() {
            return self.handshake(reg);
        }
        loop {
            let msg = match self.ws.as_mut().unwrap().read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(e)) if e.kind() == IoErrorKind::WouldBlock => break,
                Err(_) => return Outcome::Close,
            };
            match msg {
                Message::Text(t) if !self.started => {
                    if serde_json::from_str::<crate::protocol::StartMessage>(&t).is_ok() {
                        self.started = true;
                    } else {
                        return self.close(CloseCode::Protocol, REASON_NEED_START);
                    }
                }
                Message::Binary(p) if self.started && p.len() == FRAME_BYTES => {
                    self.seq += 1;
                    self.pcm.extend_from_slice(&p);
                    self.meta.push(FrameMeta {
                        seq: self.seq,
                        received_at: Instant::now(),
                    });
                }
                Message::Binary(_) if !self.started => {
                    return self.close(CloseCode::Protocol, REASON_NEED_START);
                }
                Message::Binary(_) => {
                    return self.close(CloseCode::Unsupported, REASON_BAD_FRAME_SIZE);
                }
                Message::Text(_) => {
                    return self.close(CloseCode::Protocol, REASON_TEXT_AFTER_START);
                }
                Message::Close(_) => {
                    let ws = self.ws.as_mut().unwrap();
                    let _ = ws.close(None);
                    let _ = ws.flush();
                    return Outcome::Close;
                }
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        }
        self.flush_ws(reg)
    }

    pub fn on_writable(&mut self, reg: &Registry) -> Outcome {
        self.flush_ws(reg)
    }

    /// Flush deadline elapsed and/or the in-flight request timed out.
    pub fn on_timer(&mut self, now: Instant, config: &Config) -> Tick {
        if let Some(p) = &self.pending
            && now >= p.started + INFERENCE_TIMEOUT
        {
            return Tick::Timeout(now.saturating_duration_since(p.started).as_secs_f64() * 1000.0);
        }
        if now < self.next_flush {
            return Tick::Keep;
        }
        let lateness = now.saturating_duration_since(self.next_flush).as_secs_f64() * 1000.0;
        self.next_flush += config.flush_interval;
        // One inference in flight per connection: while one is pending the
        // buffer keeps growing (back-pressure as oldest-frame latency).
        if self.pending.is_some() || self.meta.is_empty() {
            return Tick::Keep;
        }
        let first = &self.meta[0];
        let last = self.meta.last().expect("non-empty");
        Tick::Flush(Batch {
            oldest_seq: first.seq,
            newest_seq: last.seq,
            oldest_at: first.received_at,
            newest_at: last.received_at,
            frames: self.meta.len() as u64,
            audio_bytes: self.pcm.len() as u64,
            flush_lateness_ms: lateness,
        })
    }

    /// The loop handed `batch` to the inference thread; clear the buffer.
    /// Frames arriving before the result accumulate again (back-pressure
    /// as growing oldest-frame latency).
    pub fn begin_pending(&mut self, batch: Batch, started: Instant) {
        self.pending = Some(Pending { batch, started });
        self.pcm.clear();
        self.meta.clear();
    }

    /// True while a batch is awaiting the inference thread — the loop uses
    /// this to decide whether a closing connection needs an `infer.abort`.
    pub fn has_pending(&self) -> bool {
        self.pending.is_some()
    }

    /// Inference finished (or errored / timed out): emit the partial.
    pub fn deliver(
        &mut self,
        reg: &Registry,
        result: Result<InferResponse, InferError>,
        c: &Config,
    ) -> Outcome {
        let Some(p) = self.pending.take() else {
            return Outcome::Keep;
        };
        let b = p.batch;
        self.json.clear();
        let ok = match result {
            Ok(infer) => serde_json::to_writer(
                &mut self.json,
                &PartialMessage {
                    type_tag: PARTIAL_TYPE,
                    oldest_frame_seq: b.oldest_seq,
                    newest_frame_seq: b.newest_seq,
                    frames: b.frames,
                    rms: infer.rms,
                    zero_crossings: infer.zero_crossings,
                    checksum: infer.checksum,
                    samples: infer.samples,
                    transcript: infer.transcript,
                    audio_bytes: infer.audio_bytes,
                    cpu_passes: c.cpu_passes,
                    model_delay_ms: c.model_delay_ms,
                    flush_lateness_ms: b.flush_lateness_ms,
                    inflight_model_jobs: 0,
                },
            ),
            Err(e) => {
                let now = Instant::now();
                serde_json::to_writer(
                    &mut self.json,
                    &ErrorMessage {
                        type_tag: ERROR_TYPE,
                        stage: e.stage,
                        kind: e.kind,
                        message: e.message,
                        oldest_frame_seq: b.oldest_seq,
                        newest_frame_seq: b.newest_seq,
                        frames: b.frames,
                        audio_bytes: b.audio_bytes,
                        oldest_age_ms: ms(now, b.oldest_at),
                        newest_age_ms: ms(now, b.newest_at),
                        flush_lateness_ms: b.flush_lateness_ms,
                        inference_elapsed_ms: Some(e.elapsed_ms),
                        inflight_gateway_batches: 1,
                        gateway_buffer_frames: 0,
                        inference_status: e.status,
                        retryable: e.retryable,
                    },
                )
            }
        };
        if ok.is_err() {
            return Outcome::Keep;
        }
        // serde_json always emits UTF-8; never silently drop a partial —
        // a missing partial corrupts the loadgen's latency curve.
        let text = std::str::from_utf8(&self.json).expect("serde_json emits utf-8");
        if let Some(ws) = self.ws.as_mut() {
            let _ = ws.write(Message::Text(text.into()));
        }
        self.flush_ws(reg)
    }

    pub fn deregister(&mut self, reg: &Registry) {
        if let Some(s) = self.pre.as_mut() {
            let _ = reg.deregister(s);
        }
        if let Some(ws) = self.ws.as_mut() {
            let _ = reg.deregister(ws.get_mut());
        }
    }

    fn handshake(&mut self, reg: &Registry) -> Outcome {
        let stream = self.pre.as_mut().expect("pre");
        match http::feed(stream, &mut self.hs_buf) {
            Ok(Route::NeedMore) => Outcome::Keep,
            Ok(Route::Handled) | Err(_) => Outcome::Close,
            Ok(Route::WebSocket) => {
                let mut stream = self.pre.take().expect("pre");
                let _ = reg.reregister(&mut stream, ws_token(self.id), Interest::READABLE);
                self.ws = Some(WebSocket::from_raw_socket(stream, Role::Server, None));
                Outcome::Keep
            }
        }
    }

    fn flush_ws(&mut self, reg: &Registry) -> Outcome {
        let Some(ws) = self.ws.as_mut() else {
            return Outcome::Keep;
        };
        match ws.flush() {
            Ok(()) => {
                if self.ws_writable {
                    self.ws_writable = false;
                    let _ = reg.reregister(ws.get_mut(), ws_token(self.id), Interest::READABLE);
                }
                Outcome::Keep
            }
            Err(tungstenite::Error::Io(e)) if e.kind() == IoErrorKind::WouldBlock => {
                if !self.ws_writable {
                    self.ws_writable = true;
                    let _ = reg.reregister(
                        ws.get_mut(),
                        ws_token(self.id),
                        Interest::READABLE | Interest::WRITABLE,
                    );
                }
                Outcome::Keep
            }
            Err(_) => Outcome::Close,
        }
    }

    fn close(&mut self, code: CloseCode, reason: &str) -> Outcome {
        if let Some(ws) = self.ws.as_mut() {
            let _ = ws.close(Some(CloseFrame {
                code,
                reason: reason.into(),
            }));
            let _ = ws.flush();
        }
        Outcome::Close
    }
}

fn ms(now: Instant, earlier: Instant) -> f64 {
    now.saturating_duration_since(earlier).as_secs_f64() * 1000.0
}
