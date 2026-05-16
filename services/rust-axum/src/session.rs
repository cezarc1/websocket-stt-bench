//! Per-connection WebSocket session for `/ws/stt`.
//!
//! Two tasks run concurrently for each open socket:
//! - **receive loop** (`handle_socket`) reads framed PCM off the wire and
//!   pushes each `Frame` onto a shared `Arc<Mutex<Vec<Frame>>>` buffer.
//! - **flush loop** (`flush_loop`) ticks at the configured flush interval,
//!   drains the buffer into a batch, and POSTs it to the inference server.
//!   The returned `PartialMessage` is sent back to the receive loop over
//!   an `mpsc::channel` and forwarded to the client.
//!
//! A `Semaphore::new(MAX_INFLIGHT_INFERENCES)` enforces the
//! "at most one inflight inference per connection" invariant from
//! `CLAUDE.md` — back-pressure surfaces as growing oldest-frame latency
//! rather than unbounded task spawning.

use std::ops::ControlFlow;
use std::sync::{Arc, Mutex};

use axum::extract::{
    State,
    ws::{Message, WebSocket, WebSocketUpgrade},
};
use axum::response::IntoResponse;
use futures_util::SinkExt;
use rand::RngExt;
use tokio::{
    sync::{Semaphore, mpsc},
    time::{Instant, MissedTickBehavior, interval_at},
};
use tracing::warn;

use crate::config::{
    CLOSE_PROTOCOL_ERROR, CLOSE_UNSUPPORTED_DATA, FRAME_BYTES, MAX_INFLIGHT_INFERENCES,
    PARTIAL_CHANNEL_DEPTH, REASON_BAD_FRAME_SIZE, REASON_NEED_START, REASON_TEXT_AFTER_START,
    TYPICAL_BATCH,
};
use crate::inference::{InferenceContext, request_partial};
use crate::protocol::{ClientMessage, Frame};
use crate::state::AppContext;

pub(crate) async fn ws_handler(
    State(context): State<AppContext>,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    upgrade.on_upgrade(move |socket| handle_socket(socket, context))
}

async fn handle_socket(mut socket: WebSocket, context: AppContext) {
    match socket.recv().await {
        Some(Ok(Message::Text(text))) if serde_json::from_str::<ClientMessage>(&text).is_ok() => {}
        Some(Ok(_)) => {
            send_close(&mut socket, CLOSE_PROTOCOL_ERROR, REASON_NEED_START).await;
            return;
        }
        Some(Err(error)) => {
            warn!(%error, "failed to receive start message");
            return;
        }
        None => return,
    }
    // `std::sync::Mutex` (not `tokio::sync::Mutex`) is correct here: the
    // lock is held only for `push` and `mem::replace` — never across an
    // `.await` — so blocking the async runtime is impossible.
    let buffer = Arc::new(Mutex::new(Vec::<Frame>::new()));
    let compute_sem = Arc::new(Semaphore::new(MAX_INFLIGHT_INFERENCES));
    // Channel carries pre-serialized JSON (partial or error) so the writer
    // doesn't need to dispatch on variant.
    let (out_tx, mut out_rx) = mpsc::channel::<String>(PARTIAL_CHANNEL_DEPTH);
    let flusher = tokio::spawn(flush_loop(
        Arc::clone(&buffer),
        Arc::clone(&compute_sem),
        out_tx.clone(),
        context.clone(),
    ));
    let mut seq = 0_u64;
    loop {
        // `biased;` makes select! evaluate arms in source order rather than
        // randomized order. Partials drain before new frames are read, so
        // slow-client behavior shows up as oldest-frame latency growth.
        tokio::select! {
            biased;
            outbound = out_rx.recv() => {
                let Some(text) = outbound else {
                    break;
                };
                if socket.send(Message::Text(text.into())).await.is_err() {
                    break;
                }
            }
            message = socket.recv() => {
                if handle_inbound(message, &mut socket, &buffer, &mut seq).await.is_break() {
                    break;
                }
            }
        }
    }

    flusher.abort();
    drop(out_tx);
}

/// Process one inbound websocket message.
///
/// Returns `ControlFlow::Continue(())` to keep the receive loop running, or
/// `ControlFlow::Break(())` when the caller should exit (close frame
/// received, protocol violation, transport error, or stream end).
async fn handle_inbound(
    message: Option<Result<Message, axum::Error>>,
    socket: &mut WebSocket,
    buffer: &Mutex<Vec<Frame>>,
    seq: &mut u64,
) -> ControlFlow<()> {
    match message {
        Some(Ok(Message::Binary(payload))) if payload.len() == FRAME_BYTES => {
            *seq += 1;
            buffer.lock().expect("buffer mutex poisoned").push(Frame {
                seq: *seq,
                payload,
                received_at: std::time::Instant::now(),
            });
            ControlFlow::Continue(())
        }
        Some(Ok(Message::Binary(_))) => {
            send_close(socket, CLOSE_UNSUPPORTED_DATA, REASON_BAD_FRAME_SIZE).await;
            ControlFlow::Break(())
        }
        Some(Ok(Message::Text(_))) => {
            send_close(socket, CLOSE_PROTOCOL_ERROR, REASON_TEXT_AFTER_START).await;
            ControlFlow::Break(())
        }
        Some(Ok(Message::Close(_))) => {
            let _ = socket.close().await;
            ControlFlow::Break(())
        }
        Some(Ok(_)) => ControlFlow::Continue(()),
        Some(Err(error)) => {
            warn!(%error, "websocket receive error");
            ControlFlow::Break(())
        }
        None => ControlFlow::Break(()),
    }
}

async fn flush_loop(
    buffer: Arc<Mutex<Vec<Frame>>>,
    compute_sem: Arc<Semaphore>,
    out_tx: mpsc::Sender<String>,
    context: AppContext,
) {
    // One-time phase jitter de-syncs sessions that connect in a burst.
    let factor: f64 = rand::rng().random_range(0.0..1.0);
    let flush_interval = context.flush_interval;
    let start = Instant::now() + flush_interval + context.flush_phase_jitter.mul_f64(factor);
    let mut ticker = interval_at(start, flush_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut expected = start;
    loop {
        ticker.tick().await;
        let now = Instant::now();
        let flush_lateness_ms = now.saturating_duration_since(expected).as_secs_f64() * 1000.0;
        expected += flush_interval;
        let Ok(permit) = Arc::clone(&compute_sem).try_acquire_owned() else {
            continue;
        };
        let batch = {
            let mut guard = buffer.lock().expect("buffer mutex poisoned");
            if guard.is_empty() {
                drop(permit);
                continue;
            }
            std::mem::replace(&mut *guard, Vec::with_capacity(TYPICAL_BATCH))
        };
        let _permit = permit;
        // gateway_buffer_frames is sampled lazily — only on the error
        // path — via this closure. The receive loop may push frames after
        // we drained, and the value reflects buffer pressure at the
        // moment the error is emitted, not at flush start.
        let inference_context = InferenceContext {
            flush_lateness_ms,
            gateway_buffer_frames_at_error: || buffer.lock().expect("buffer mutex poisoned").len(),
        };
        let outbound = match request_partial(&context, batch, inference_context).await {
            Ok(partial) => serde_json::to_string(&partial),
            Err(error) => serde_json::to_string(&error),
        };
        if let Ok(text) = outbound {
            let _ = out_tx.send(text).await;
        }
    }
}

async fn send_close(socket: &mut WebSocket, code: u16, reason: &str) {
    let _ = socket
        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: reason.to_owned().into(),
        })))
        .await;
    let _ = socket.close().await;
}
