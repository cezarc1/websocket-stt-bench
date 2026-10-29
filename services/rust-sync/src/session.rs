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

impl Batch {
    /// Unique per connection (seqs strictly increase), so it identifies
    /// this batch's inference request across the thread handoff.
    pub fn tag(&self) -> u64 {
        self.oldest_seq
    }
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

    /// Dispatch one epoll event. mio is edge-triggered, so an event that
    /// is both readable and writable must still drain the read side —
    /// otherwise a client Close (or the last frames) that arrived alongside
    /// send-buffer space is never read. `on_readable` also flushes.
    pub fn on_ready(&mut self, reg: &Registry, readable: bool, writable: bool) -> Outcome {
        if readable {
            self.on_readable(reg)
        } else if writable {
            self.on_writable(reg)
        } else {
            Outcome::Keep
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

    /// Thread B finished the request tagged `tag`. After a local timeout
    /// the next batch may already be pending when the abandoned request's
    /// late result arrives; delivering it would attach the old batch's
    /// stats to the new batch's seq range, so a non-matching tag is dropped.
    pub fn on_done(
        &mut self,
        reg: &Registry,
        tag: u64,
        result: Result<InferResponse, InferError>,
        c: &Config,
    ) -> Outcome {
        match &self.pending {
            Some(p) if p.batch.tag() == tag => self.deliver(reg, result, c),
            _ => Outcome::Keep,
        }
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

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream as StdStream};
    use std::time::Duration;

    use mio::Poll;

    use super::*;

    fn config() -> Config {
        Config {
            port: 0,
            inference_host: "127.0.0.1".to_owned(),
            inference_port: 9,
            inference_path: "/infer".to_owned(),
            inference_clients: 1,
            cpu_passes: 4,
            model_delay_ms: 75,
            flush_interval: Duration::from_millis(1000),
            flush_phase_jitter: Duration::ZERO,
        }
    }

    /// A registered server-side `Conn` plus the client end of the socket.
    fn conn_pair(poll: &Poll) -> (Conn, StdStream) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = StdStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        server.set_nonblocking(true).unwrap();
        let mut stream = TcpStream::from_std(server);
        poll.registry()
            .register(&mut stream, ws_token(7), Interest::READABLE)
            .unwrap();
        (Conn::new(7, stream, &config()), client)
    }

    fn push_frames(conn: &mut Conn, n: usize) {
        for _ in 0..n {
            conn.seq += 1;
            conn.pcm.extend_from_slice(&[0u8; FRAME_BYTES]);
            conn.meta.push(FrameMeta {
                seq: conn.seq,
                received_at: Instant::now(),
            });
        }
    }

    fn flush_now(conn: &mut Conn, now: Instant) -> Batch {
        conn.next_flush = now;
        match conn.on_timer(now, &config()) {
            Tick::Flush(batch) => batch,
            _ => panic!("expected a flush"),
        }
    }

    fn infer_ok() -> Result<InferResponse, InferError> {
        Ok(InferResponse {
            rms: 0.0,
            zero_crossings: 0,
            checksum: 0,
            samples: 0,
            transcript: "now".to_owned(),
            audio_bytes: 0,
        })
    }

    /// Regression: after a local timeout the next batch is submitted; the
    /// abandoned request's late `Done` must not be attributed to it.
    #[test]
    fn late_result_of_timed_out_batch_is_dropped() {
        let poll = Poll::new().unwrap();
        let (mut conn, _client) = conn_pair(&poll);
        let reg = poll.registry();
        let c = config();
        let now = Instant::now();

        push_frames(&mut conn, 3);
        let first = flush_now(&mut conn, now);
        let first_tag = first.tag();
        conn.begin_pending(first, now.checked_sub(INFERENCE_TIMEOUT).unwrap());
        let Tick::Timeout(elapsed) = conn.on_timer(now, &c) else {
            panic!("expected timeout");
        };
        conn.deliver(reg, Err(crate::inference::timeout_error(elapsed)), &c);
        assert!(!conn.has_pending());

        push_frames(&mut conn, 2);
        let second = flush_now(&mut conn, now);
        let second_tag = second.tag();
        assert_eq!((first_tag, second_tag), (1, 4));
        conn.begin_pending(second, now);

        conn.on_done(reg, first_tag, infer_ok(), &c);
        assert!(conn.has_pending(), "stale result consumed the new batch");
        conn.on_done(reg, second_tag, infer_ok(), &c);
        assert!(!conn.has_pending());
    }

    /// Regression: an edge-triggered event that is readable *and* writable
    /// must still read, or a client Close arriving with it is never seen.
    #[test]
    fn readable_and_writable_event_still_reads_close() {
        let poll = Poll::new().unwrap();
        let (mut conn, mut client) = conn_pair(&poll);
        let reg = poll.registry();
        client
            .write_all(
                b"GET /ws/stt HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                  Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
            )
            .unwrap();
        for _ in 0..200 {
            if conn.ws.is_some() {
                break;
            }
            assert!(matches!(conn.on_ready(reg, true, false), Outcome::Keep));
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(conn.ws.is_some(), "handshake did not complete");
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            client.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }

        let mut ws = WebSocket::from_raw_socket(client, Role::Client, None);
        ws.send(Message::Text(r#"{"type":"start"}"#.into()))
            .unwrap();
        ws.close(None).unwrap();

        let mut closed = false;
        for _ in 0..200 {
            if matches!(conn.on_ready(reg, true, true), Outcome::Close) {
                closed = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(conn.started, "start message was not read");
        assert!(closed, "client Close was not processed");
    }
}
