use std::collections::BTreeSet;
use std::time::Duration;

use anyhow::{Context, ensure};
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use stt_loadgen::{
    protocol::{
        FLUSH_INTERVAL, FRAME_BYTES, FRAME_INTERVAL, GOLDEN_ONE_FRAME, PartialMessage,
        ServerMessage, StartMessage, frame_payload,
    },
    verify::{Continuity, ExpectedConfig, rms_matches, verify_partial},
};
use tokio::net::TcpStream;
use tokio::time::{Instant, sleep, sleep_until, timeout};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{Error as WsError, Message},
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const READY_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(3);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

/// Non-zero, pairwise-distinct session ids. `frame_payload` mixes the id into
/// every sample, so a gateway that serves one connection's audio (or result)
/// on another produces checksums that fail `verify_partial`. The frame seed is
/// a non-linear hash of (session, seq), so distinct pairs never share content
/// and any distinct ids work; these are arbitrary.
const MULTI_FRAME_SESSION: usize = 7_919;
const CADENCE_SESSION: usize = 101;
const ISOLATION_SESSIONS: [usize; 2] = [211, 422];
/// One full flush interval of audio.
const MULTI_FRAME_COUNT: u64 = (FLUSH_INTERVAL.as_millis() / FRAME_INTERVAL.as_millis()) as u64;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long = "service", value_parser = parse_service)]
    services: Vec<ServiceTarget>,
    /// `cpu_passes` every partial must echo (gateway `CPU_PASSES`).
    #[arg(long, default_value_t = ExpectedConfig::default().cpu_passes)]
    expect_cpu_passes: u32,
    /// `model_delay_ms` every partial must echo (gateway `MODEL_DELAY_MS`).
    #[arg(long, default_value_t = ExpectedConfig::default().model_delay_ms)]
    expect_model_delay_ms: u64,
}

#[derive(Clone, Debug)]
struct ServiceTarget {
    name: String,
    url: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    ensure!(
        !args.services.is_empty(),
        "at least one --service name=url is required"
    );

    let expected = ExpectedConfig {
        cpu_passes: args.expect_cpu_passes,
        model_delay_ms: args.expect_model_delay_ms,
    };
    let mut failures = Vec::new();
    for target in args.services {
        print!("{} ... ", target.name);
        match run_service(&target, expected).await {
            Ok(()) => println!("ok"),
            Err(error) => {
                println!("FAILED");
                failures.push(format!("{}: {error:#}", target.name));
            }
        }
    }

    if failures.is_empty() {
        return Ok(());
    }

    for failure in failures {
        eprintln!("{failure}");
    }
    anyhow::bail!("conformance failed");
}

async fn run_service(target: &ServiceTarget, expected: ExpectedConfig) -> anyhow::Result<()> {
    wait_until_ready(target).await?;
    partial_schema_and_golden(target, expected)
        .await
        .context("partial schema and golden stub")?;
    multi_frame_golden(target, expected)
        .await
        .context("multi-frame golden")?;
    invalid_start_closes(target)
        .await
        .context("invalid start close code")?;
    invalid_frame_closes(target)
        .await
        .context("invalid frame close code")?;
    flush_cadence(target, expected)
        .await
        .context("flush cadence")?;
    concurrent_isolation(target, expected)
        .await
        .context("concurrent session isolation")?;
    normal_close(target).await.context("normal close")?;
    Ok(())
}

/// Per-connection response checker: every partial must tile the frame
/// sequence (`oldest == prev_newest + 1`), only cover frames actually sent,
/// and carry exactly the stub output for those frames of `session_id`.
struct PartialChecker {
    session_id: usize,
    expected: ExpectedConfig,
    continuity: Continuity,
    scratch: Vec<u8>,
}

impl PartialChecker {
    fn new(session_id: usize, expected: ExpectedConfig) -> Self {
        Self {
            session_id,
            expected,
            continuity: Continuity::default(),
            scratch: Vec::new(),
        }
    }

    fn check(&mut self, partial: &PartialMessage, frames_sent: u64) -> anyhow::Result<()> {
        let range = format!(
            "session {} partial {}..={}",
            self.session_id, partial.oldest_frame_seq, partial.newest_frame_seq
        );
        // Observe before validating so a partial failing another check still
        // consumes its range and the next one is not also flagged as a gap.
        let continuity = self
            .continuity
            .observe(partial.oldest_frame_seq, partial.newest_frame_seq);
        partial.validate().with_context(|| range.clone())?;
        if let Some(mismatch) = continuity {
            anyhow::bail!("{range}: {mismatch}");
        }
        ensure!(
            partial.newest_frame_seq <= frames_sent,
            "{range}: covers frames not yet sent (sent {frames_sent})"
        );
        let mismatches = verify_partial(self.session_id, partial, self.expected, &mut self.scratch);
        if !mismatches.is_empty() {
            let details = mismatches
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join("; ");
            anyhow::bail!("{range}: {details}");
        }
        Ok(())
    }

    fn covered(&self) -> u64 {
        self.continuity.last_newest()
    }
}

async fn wait_until_ready(target: &ServiceTarget) -> anyhow::Result<()> {
    let deadline = Instant::now() + READY_TIMEOUT;

    loop {
        match timeout(CONNECT_TIMEOUT, connect_async(&target.url)).await {
            Ok(Ok((mut socket, _response))) => {
                let _ = socket.send(Message::Close(None)).await;
                return Ok(());
            }
            Ok(Err(error)) => {
                if Instant::now() >= deadline {
                    return Err(error).with_context(|| format!("connect {}", target.url));
                }
            }
            Err(_elapsed) => {
                if Instant::now() >= deadline {
                    anyhow::bail!("connect {} timed out", target.url);
                }
            }
        }
        sleep(Duration::from_millis(500)).await;
    }
}

async fn partial_schema_and_golden(
    target: &ServiceTarget,
    expected: ExpectedConfig,
) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    socket
        .send(Message::Binary(frame_payload(0, 1).into()))
        .await
        .context("send golden frame")?;

    let (raw, partial) = read_partial(&mut socket, READ_TIMEOUT).await?;
    partial.validate()?;
    assert_schema_fields(&raw)?;
    ensure!(partial.oldest_frame_seq == 1, "oldest_frame_seq mismatch");
    ensure!(partial.newest_frame_seq == 1, "newest_frame_seq mismatch");
    ensure!(partial.frames == GOLDEN_ONE_FRAME.frames, "frames mismatch");
    ensure!(
        partial.samples == GOLDEN_ONE_FRAME.samples,
        "sample count mismatch"
    );
    ensure!(
        partial.checksum == GOLDEN_ONE_FRAME.checksum,
        "checksum mismatch: got {}, expected {}",
        partial.checksum,
        GOLDEN_ONE_FRAME.checksum
    );
    ensure!(
        partial.zero_crossings == GOLDEN_ONE_FRAME.zero_crossings,
        "zero crossings mismatch"
    );
    ensure!(
        rms_matches(partial.rms, GOLDEN_ONE_FRAME.rms),
        "rms mismatch: got {}, expected {}",
        partial.rms,
        GOLDEN_ONE_FRAME.rms
    );
    ensure!(
        partial.transcript == GOLDEN_ONE_FRAME.transcript,
        "transcript mismatch: got {:?}, expected {:?}",
        partial.transcript,
        GOLDEN_ONE_FRAME.transcript
    );
    ensure!(
        partial.audio_bytes == GOLDEN_ONE_FRAME.audio_bytes,
        "audio_bytes mismatch: got {}, expected {}",
        partial.audio_bytes,
        GOLDEN_ONE_FRAME.audio_bytes
    );
    // Also exercises cpu_passes / model_delay_ms echo and the shared helper.
    PartialChecker::new(0, expected).check(&partial, 1)?;

    let _ = socket.send(Message::Close(None)).await;
    Ok(())
}

/// Burst one flush interval of frames from a non-zero session and verify the
/// partial(s) covering them against the shared stub. A 1-frame golden cannot
/// catch per-batch bugs (dropped/reordered/duplicated frames inside a batch,
/// wrong concatenation, partial batches); this can.
async fn multi_frame_golden(
    target: &ServiceTarget,
    expected: ExpectedConfig,
) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    for seq in 1..=MULTI_FRAME_COUNT {
        socket
            .send(Message::Binary(
                frame_payload(MULTI_FRAME_SESSION, seq).into(),
            ))
            .await
            .context("send multi-frame batch")?;
    }

    let mut checker = PartialChecker::new(MULTI_FRAME_SESSION, expected);
    let mut partials = 0_u32;
    while checker.covered() < MULTI_FRAME_COUNT {
        // Allow a full extra flush interval: the first flush tick may carry
        // up to FLUSH_PHASE_JITTER of initial phase offset.
        let (_raw, partial) = read_partial(&mut socket, READ_TIMEOUT + FLUSH_INTERVAL)
            .await
            .with_context(|| {
                format!(
                    "waiting for frames {}..={MULTI_FRAME_COUNT}",
                    checker.covered() + 1
                )
            })?;
        checker.check(&partial, MULTI_FRAME_COUNT)?;
        partials += 1;
    }
    // A burst normally lands in a single flush; a flush tick mid-burst may
    // legitimately split it, but more than two partials means the gateway is
    // not batching per flush interval.
    ensure!(
        partials <= 2,
        "{MULTI_FRAME_COUNT} burst frames arrived in {partials} partials"
    );

    let _ = socket.send(Message::Close(None)).await;
    Ok(())
}

/// "Invalid first messages close with WebSocket code 1002." Only cases the
/// contract settles are tested: not JSON, JSON that is not a start message,
/// and a binary frame where the start message must be. (A start carrying
/// extra fields is deliberately not tested — the contract doesn't say.)
async fn invalid_start_closes(target: &ServiceTarget) -> anyhow::Result<()> {
    let cases: [(&str, Message); 3] = [
        ("non-JSON text", Message::Text("not-json".into())),
        (
            r#"wrong type {"type":"stop"}"#,
            Message::Text(r#"{"type":"stop"}"#.into()),
        ),
        (
            "binary frame before start",
            Message::Binary(frame_payload(0, 1).into()),
        ),
    ];
    for (label, first) in cases {
        let mut socket = connect(target).await?;
        socket
            .send(first)
            .await
            .with_context(|| format!("send invalid start ({label})"))?;
        expect_close_code(&mut socket, 1002, CLOSE_TIMEOUT)
            .await
            .with_context(|| format!("invalid start: {label}"))?;
    }
    Ok(())
}

/// "Invalid binary frame sizes close with code 1003."
async fn invalid_frame_closes(target: &ServiceTarget) -> anyhow::Result<()> {
    for size in [0, 10, FRAME_BYTES - 1, FRAME_BYTES + 1, 8_193, 65_536] {
        let mut socket = connect(target).await?;
        send_start(&mut socket).await?;
        socket
            .send(Message::Binary(vec![0_u8; size].into()))
            .await
            .with_context(|| format!("send {size}-byte binary frame"))?;
        expect_close_code(&mut socket, 1003, CLOSE_TIMEOUT)
            .await
            .with_context(|| format!("invalid frame size {size}"))?;
    }
    Ok(())
}

/// Stream real-time paced frames for `session_id` until at least
/// `min_partials` partials arrived and `send_for` elapsed. Every partial is
/// checked for continuity and exact values; returns their arrival times.
async fn stream_paced(
    target: &ServiceTarget,
    session_id: usize,
    expected: ExpectedConfig,
    min_partials: usize,
    send_for: Duration,
    give_up_after: Duration,
) -> anyhow::Result<Vec<Instant>> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    let (mut write, mut read) = socket.split();
    let started = Instant::now();
    let stop_sending = started + send_for;
    let deadline = started + give_up_after;
    let mut next_frame = started;
    let mut sent = 0_u64;
    let mut checker = PartialChecker::new(session_id, expected);
    let mut partial_times = Vec::new();

    loop {
        if partial_times.len() >= min_partials && Instant::now() >= stop_sending {
            break;
        }

        tokio::select! {
            () = sleep_until(next_frame), if Instant::now() < stop_sending => {
                write
                    .send(Message::Binary(frame_payload(session_id, sent + 1).into()))
                    .await
                    .context("send paced frame")?;
                sent += 1;
                next_frame += FRAME_INTERVAL;
            }
            message = read.next() => {
                let Some(message) = message else {
                    anyhow::bail!("socket closed before {min_partials} partials");
                };
                match message.context("read paced message")? {
                    Message::Text(text) => {
                        let partial = expect_partial(&text)
                            .context("decode paced message")?;
                        checker.check(&partial, sent)?;
                        partial_times.push(Instant::now());
                    }
                    Message::Close(frame) => {
                        anyhow::bail!("server closed while streaming: {frame:?}");
                    }
                    _ => {}
                }
            }
            () = sleep_until(deadline) => {
                anyhow::bail!(
                    "timed out with {} of {min_partials} partials",
                    partial_times.len()
                );
            }
        }
    }

    let _ = write.send(Message::Close(None)).await;
    Ok(partial_times)
}

/// Flush intervals the cadence case observes. Must exceed 10 so a gateway
/// that skips one flush in ten (its frames then ride along in the next
/// partial, so continuity and values still pass) is caught by the interval
/// bound. Costs ~13 s per service.
const CADENCE_INTERVALS: usize = 12;

async fn flush_cadence(target: &ServiceTarget, expected: ExpectedConfig) -> anyhow::Result<()> {
    let partials = CADENCE_INTERVALS + 1;
    // Keep sending through the last expected partial; `stream_paced` checks
    // continuity and exact values on every one of them.
    let send_for = FLUSH_INTERVAL * partials as u32 + Duration::from_millis(250);
    let partial_times = stream_paced(
        target,
        CADENCE_SESSION,
        expected,
        partials,
        send_for,
        send_for + Duration::from_secs(4),
    )
    .await?;

    ensure!(
        partial_times.len() >= partials,
        "expected at least {partials} partials, got {}",
        partial_times.len()
    );
    for (index, window) in partial_times.windows(2).enumerate() {
        let interval = window[1].saturating_duration_since(window[0]);
        ensure!(
            interval >= FLUSH_INTERVAL.saturating_sub(Duration::from_millis(250)),
            "partial interval {} below tolerance: {interval:?}",
            index + 1
        );
        ensure!(
            interval <= FLUSH_INTERVAL + Duration::from_millis(500),
            "partial interval {} above tolerance: {interval:?} (skipped flush?)",
            index + 1
        );
    }
    ensure!(
        partial_times[1].saturating_duration_since(partial_times[0])
            <= FLUSH_INTERVAL + Duration::from_millis(250),
        "first cadence interval too wide"
    );
    Ok(())
}

/// Two simultaneous connections with different session ids. Each one's
/// partials must match its own audio exactly; any shared buffer, swapped
/// response routing, or cross-connection seq counter fails `verify_partial`
/// or continuity on at least one side.
async fn concurrent_isolation(
    target: &ServiceTarget,
    expected: ExpectedConfig,
) -> anyhow::Result<()> {
    let [left, right] = ISOLATION_SESSIONS;
    let stream = |session_id| {
        stream_paced(
            target,
            session_id,
            expected,
            2,
            Duration::from_millis(2_250),
            Duration::from_secs(6),
        )
    };
    let (left_result, right_result) = tokio::join!(stream(left), stream(right));
    left_result.with_context(|| format!("session {left}"))?;
    right_result.with_context(|| format!("session {right}"))?;
    Ok(())
}

async fn normal_close(target: &ServiceTarget) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    socket
        .send(Message::Binary(frame_payload(0, 1).into()))
        .await
        .context("send pre-close frame")?;
    socket
        .send(Message::Close(None))
        .await
        .context("send normal close")?;

    let deadline = Instant::now() + CLOSE_TIMEOUT;
    loop {
        tokio::select! {
            message = socket.next() => {
                match message {
                    Some(Ok(Message::Close(_frame))) => return Ok(()),
                    Some(Ok(Message::Text(_))) => {}
                    Some(Ok(_)) => {}
                    Some(Err(WsError::ConnectionClosed | WsError::AlreadyClosed)) => return Ok(()),
                    Some(Err(error)) => return Err(error).context("read normal close"),
                    None => return Ok(()),
                }
            }
            () = sleep_until(deadline) => {
                anyhow::bail!("normal close did not complete within {CLOSE_TIMEOUT:?}");
            }
        }
    }
}

async fn connect(
    target: &ServiceTarget,
) -> anyhow::Result<WebSocketStream<MaybeTlsStream<TcpStream>>> {
    let (socket, _response) = timeout(CONNECT_TIMEOUT, connect_async(&target.url))
        .await
        .with_context(|| format!("connect {} timed out", target.url))?
        .with_context(|| format!("connect {}", target.url))?;
    Ok(socket)
}

async fn send_start(socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>) -> anyhow::Result<()> {
    let start = serde_json::to_string(&StartMessage::Start)?;
    socket
        .send(Message::Text(start.into()))
        .await
        .context("send start")
}

/// Decode a server-to-client text frame as a `PartialMessage`, bailing if
/// it's an error frame instead. Conformance assumes a healthy infra path,
/// so any error frame is unexpected.
fn expect_partial(text: &str) -> anyhow::Result<PartialMessage> {
    let server_message: ServerMessage =
        serde_json::from_str(text).context("decode server message")?;
    match server_message {
        ServerMessage::Partial(partial) => Ok(partial),
        ServerMessage::Error(error) => anyhow::bail!(
            "unexpected error frame: stage={} kind={} message={}",
            error.stage,
            error.kind,
            error.message
        ),
    }
}

async fn read_partial<S>(
    read: &mut S,
    duration: Duration,
) -> anyhow::Result<(String, PartialMessage)>
where
    S: StreamExt<Item = Result<Message, WsError>> + Unpin,
{
    let deadline = Instant::now() + duration;
    loop {
        tokio::select! {
            message = read.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let partial = expect_partial(&text)?;
                        return Ok((text.to_string(), partial));
                    }
                    Some(Ok(Message::Close(frame))) => {
                        anyhow::bail!("server closed before partial: {frame:?}");
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(error).context("read partial"),
                    None => anyhow::bail!("socket closed before partial"),
                }
            }
            () = sleep_until(deadline) => {
                anyhow::bail!("timed out waiting for partial");
            }
        }
    }
}

async fn expect_close_code<S>(
    read: &mut S,
    expected_code: u16,
    duration: Duration,
) -> anyhow::Result<()>
where
    S: StreamExt<Item = Result<Message, WsError>> + Unpin,
{
    let deadline = Instant::now() + duration;
    tokio::select! {
        message = read.next() => {
            match message {
                Some(Ok(Message::Close(Some(frame)))) => {
                    let actual = u16::from(frame.code);
                    ensure!(
                        actual == expected_code,
                        "close code mismatch: got {actual}, expected {expected_code}"
                    );
                    Ok(())
                }
                Some(Ok(Message::Close(None))) => {
                    anyhow::bail!("server close frame omitted code, expected {expected_code}");
                }
                Some(Ok(message)) => {
                    anyhow::bail!("expected close frame, got {message:?}");
                }
                Some(Err(error)) => Err(error).context("read close frame"),
                None => anyhow::bail!("socket closed without close frame"),
            }
        }
        () = sleep_until(deadline) => {
            anyhow::bail!("timed out waiting for close code {expected_code}");
        }
    }
}

fn assert_schema_fields(raw: &str) -> anyhow::Result<()> {
    let value: Value = serde_json::from_str(raw).context("parse partial as Value")?;
    let Value::Object(object) = value else {
        anyhow::bail!("partial did not serialize as an object");
    };
    let actual = object.keys().cloned().collect::<BTreeSet<_>>();
    let expected = [
        "type",
        "oldest_frame_seq",
        "newest_frame_seq",
        "frames",
        "rms",
        "zero_crossings",
        "checksum",
        "samples",
        "transcript",
        "audio_bytes",
        "cpu_passes",
        "model_delay_ms",
        "flush_lateness_ms",
        "inflight_model_jobs",
    ]
    .into_iter()
    .map(str::to_string)
    .collect::<BTreeSet<_>>();
    ensure!(actual == expected, "partial field set mismatch: {actual:?}");
    Ok(())
}

fn parse_service(raw: &str) -> Result<ServiceTarget, String> {
    let (name, url) = raw
        .split_once('=')
        .ok_or_else(|| "expected --service name=ws://host:port/ws/stt".to_string())?;
    if name.is_empty() || url.is_empty() {
        return Err("service name and url must be non-empty".to_string());
    }
    Ok(ServiceTarget {
        name: name.to_string(),
        url: url.to_string(),
    })
}
