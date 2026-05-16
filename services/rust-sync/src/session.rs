//! One connection = one OS thread, blocking I/O.
//!
//! The flush cadence *is* the socket read timeout: each turn it is set to
//! the time remaining until the next flush, so a blocking `ws.read()`
//! never overruns the deadline (a fixed/coarse timeout was tried and
//! broke cadence — when the client pauses, a blocking read sails past the
//! flush boundary; the per-turn `setsockopt` is load-bearing, not
//! removable, for this thread-per-connection design). While the thread is
//! parked in the inference POST
//! the kernel buffers inbound frames; they drain on the next read, so
//! back-pressure surfaces as growing oldest-frame latency exactly as the
//! contract requires. The one-inflight invariant is structural: the
//! thread cannot issue a second POST until the first returns.

use std::io::ErrorKind as IoErrorKind;
use std::net::TcpStream;
use std::ops::ControlFlow::{self, Break, Continue};
use std::time::{Duration, Instant};

use rand::RngExt;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::{CloseFrame, Role};
use tungstenite::{Message, WebSocket};

use crate::config::{
    Config, FRAME_BYTES, REASON_BAD_FRAME_SIZE, REASON_NEED_START, REASON_TEXT_AFTER_START,
};
use crate::http::{self, Route};
use crate::inference::{Inference, InferenceError};
use crate::protocol::{ERROR_TYPE, ErrorMessage, PARTIAL_TYPE, PartialMessage, StartMessage};

/// Generous ceiling for receiving `{"type":"start"}`. A silent client
/// must not pin a thread forever; the loadgen sends it immediately.
const START_TIMEOUT: Duration = Duration::from_secs(10);

struct FrameMeta {
    seq: u64,
    received_at: Instant,
}

/// Per-connection scratch, reused for the connection's lifetime. PCM is
/// accumulated straight into the POST body (no per-frame allocation, no
/// separate concat step); `meta` carries per-frame identity; `json` is
/// the serialization buffer for the outbound text frame.
struct Scratch {
    pcm: Vec<u8>,
    meta: Vec<FrameMeta>,
    json: Vec<u8>,
}

impl Scratch {
    fn new() -> Self {
        Self {
            pcm: Vec::with_capacity(64 * FRAME_BYTES),
            meta: Vec::with_capacity(64),
            json: Vec::with_capacity(512),
        }
    }

    fn clear(&mut self) {
        self.pcm.clear();
        self.meta.clear();
        self.json.clear();
    }
}

pub fn serve(mut stream: TcpStream, config: &Config) {
    let _ = stream.set_nodelay(true);
    match http::handshake(&mut stream) {
        Ok(Route::WebSocket) => {}
        Ok(Route::Handled) | Err(_) => return,
    }
    let mut ws = WebSocket::from_raw_socket(stream, Role::Server, None);
    if !await_start(&mut ws) {
        return;
    }
    run(&mut ws, config);
}

/// First message must be `{"type":"start"}` (text). Anything else closes
/// 1002. Returns whether the stream may proceed.
fn await_start(ws: &mut WebSocket<TcpStream>) -> bool {
    let _ = ws.get_ref().set_read_timeout(Some(START_TIMEOUT));
    match ws.read() {
        Ok(Message::Text(text)) if serde_json::from_str::<StartMessage>(&text).is_ok() => true,
        Ok(Message::Close(_)) | Err(_) => false,
        // Invalid first message (bad/oversized text, binary, etc.) → 1002.
        Ok(_) => {
            close(ws, CloseCode::Protocol, REASON_NEED_START);
            false
        }
    }
}

fn run(ws: &mut WebSocket<TcpStream>, config: &Config) {
    let mut inference = Inference::new();
    let mut scratch = Scratch::new();
    let mut seq: u64 = 0;

    let jitter_ms = config.flush_phase_jitter.as_millis() as u64;
    let phase = if jitter_ms == 0 {
        Duration::ZERO
    } else {
        Duration::from_millis(rand::rng().random_range(0..=jitter_ms))
    };
    // `expected` advances by exactly one interval per flush (rust-axum's
    // `MissedTickBehavior::Delay` equivalent): under overload it falls
    // behind `now`, so `flush_lateness_ms` grows — the intended signal.
    let mut expected = Instant::now() + config.flush_interval + phase;

    loop {
        let remaining = expected.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            if flush(ws, config, &mut inference, &mut scratch, expected).is_break() {
                return;
            }
            expected += config.flush_interval;
            continue;
        }

        // Bounds the blocking read at the flush deadline.
        let _ = ws.get_ref().set_read_timeout(Some(remaining));
        match ws.read() {
            Ok(Message::Binary(payload)) if payload.len() == FRAME_BYTES => {
                seq += 1;
                scratch.pcm.extend_from_slice(&payload);
                scratch.meta.push(FrameMeta {
                    seq,
                    received_at: Instant::now(),
                });
            }
            Ok(Message::Binary(_)) => {
                close(ws, CloseCode::Unsupported, REASON_BAD_FRAME_SIZE);
                return;
            }
            Ok(Message::Text(_)) => {
                close(ws, CloseCode::Protocol, REASON_TEXT_AFTER_START);
                return;
            }
            Ok(Message::Close(_)) => {
                // Complete the closing handshake so the client sees a
                // clean close, not a TCP reset. No final drained partial.
                let _ = ws.close(None);
                let _ = ws.flush();
                return;
            }
            // Ping/Pong/Frame: tungstenite queues the pong itself.
            Ok(_) => {}
            // Idle read timeout; the loop re-checks the flush deadline.
            Err(tungstenite::Error::Io(e))
                if matches!(e.kind(), IoErrorKind::WouldBlock | IoErrorKind::TimedOut) => {}
            Err(_) => return,
        }
    }
}

fn flush(
    ws: &mut WebSocket<TcpStream>,
    config: &Config,
    inference: &mut Inference,
    scratch: &mut Scratch,
    expected: Instant,
) -> ControlFlow<()> {
    let now = Instant::now();
    let flush_lateness_ms = now.saturating_duration_since(expected).as_secs_f64() * 1000.0;
    let Some(first) = scratch.meta.first() else {
        return Continue(());
    };
    let last = scratch.meta.last().expect("meta non-empty");
    let (oldest_seq, oldest_at) = (first.seq, first.received_at);
    let (newest_seq, newest_at) = (last.seq, last.received_at);
    let frames = scratch.meta.len() as u64;
    let audio_bytes = scratch.pcm.len() as u64;

    let result = inference.infer(config, &scratch.pcm);

    let serialized = match result {
        Ok((infer, _elapsed)) => serde_json::to_writer(
            &mut scratch.json,
            &PartialMessage {
                type_tag: PARTIAL_TYPE,
                oldest_frame_seq: oldest_seq,
                newest_frame_seq: newest_seq,
                frames,
                rms: infer.rms,
                zero_crossings: infer.zero_crossings,
                checksum: infer.checksum,
                samples: infer.samples,
                transcript: infer.transcript,
                audio_bytes: infer.audio_bytes,
                cpu_passes: config.cpu_passes,
                model_delay_ms: config.model_delay_ms,
                flush_lateness_ms,
                inflight_model_jobs: 0,
            },
        ),
        Err(InferenceError {
            stage,
            kind,
            message,
            status,
            retryable,
            elapsed,
        }) => {
            let after = Instant::now();
            serde_json::to_writer(
                &mut scratch.json,
                &ErrorMessage {
                    type_tag: ERROR_TYPE,
                    stage,
                    kind,
                    message,
                    oldest_frame_seq: oldest_seq,
                    newest_frame_seq: newest_seq,
                    frames,
                    audio_bytes,
                    oldest_age_ms: duration_ms(after, oldest_at),
                    newest_age_ms: duration_ms(after, newest_at),
                    flush_lateness_ms,
                    inference_elapsed_ms: Some(elapsed.as_secs_f64() * 1000.0),
                    inflight_gateway_batches: 1,
                    gateway_buffer_frames: 0,
                    inference_status: status,
                    retryable,
                },
            )
        }
    };

    let outcome = if serialized.is_ok() {
        let text = std::str::from_utf8(&scratch.json).expect("serde_json emits utf8");
        match ws.send(Message::Text(text.into())) {
            Ok(()) => Continue(()),
            Err(_) => Break(()),
        }
    } else {
        Continue(())
    };
    scratch.clear();
    outcome
}

fn duration_ms(now: Instant, earlier: Instant) -> f64 {
    now.saturating_duration_since(earlier).as_secs_f64() * 1000.0
}

fn close(ws: &mut WebSocket<TcpStream>, code: CloseCode, reason: &str) {
    let _ = ws.close(Some(CloseFrame {
        code,
        reason: reason.into(),
    }));
    let _ = ws.flush();
}

#[cfg(test)]
mod tests {
    use std::io::{self, Cursor, Read, Write};

    use tungstenite::protocol::Role;
    use tungstenite::{Message, WebSocket};

    /// Encode a properly-masked client→server binary frame by driving a
    /// client-role tungstenite over an in-memory buffer.
    fn client_binary_frame(payload: &[u8]) -> Vec<u8> {
        let mut client = WebSocket::from_raw_socket(Cursor::new(Vec::new()), Role::Client, None);
        client
            .send(Message::Binary(payload.to_vec().into()))
            .unwrap();
        client.into_inner().into_inner()
    }

    /// Yields `bytes` in two halves with exactly one `WouldBlock` injected
    /// between them, simulating a read deadline firing mid-frame.
    struct SplitOnce {
        bytes: Vec<u8>,
        pos: usize,
        split: usize,
        blocked: bool,
    }

    impl Read for SplitOnce {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            if self.pos == self.split && !self.blocked {
                self.blocked = true;
                return Err(io::Error::from(io::ErrorKind::WouldBlock));
            }
            if self.pos >= self.bytes.len() {
                return Ok(0);
            }
            let end = if self.pos < self.split {
                self.split
            } else {
                self.bytes.len()
            };
            let n = (end - self.pos).min(out.len());
            out[..n].copy_from_slice(&self.bytes[self.pos..self.pos + n]);
            self.pos += n;
            Ok(n)
        }
    }

    impl Write for SplitOnce {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn timeout_mid_frame_resumes_cleanly() {
        let payload = vec![7u8; super::FRAME_BYTES];
        let frame = client_binary_frame(&payload);
        let split = frame.len() / 2;
        let stream = SplitOnce {
            bytes: frame,
            pos: 0,
            split,
            blocked: false,
        };
        let mut server = WebSocket::from_raw_socket(stream, Role::Server, None);

        match server.read() {
            Err(tungstenite::Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => {}
            other => panic!("expected WouldBlock mid-frame, got {other:?}"),
        }
        match server.read() {
            Ok(Message::Binary(got)) => assert_eq!(&got[..], &payload[..]),
            other => panic!("expected resumed binary frame, got {other:?}"),
        }
    }
}
