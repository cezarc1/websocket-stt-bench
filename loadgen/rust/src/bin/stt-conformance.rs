use std::collections::BTreeSet;
use std::time::Duration;

use anyhow::{Context, ensure};
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use stt_loadgen::protocol::{
    FLUSH_INTERVAL, FRAME_INTERVAL, GOLDEN_ONE_FRAME, PartialMessage, ServerMessage, StartMessage,
    frame_payload,
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
const GOLDEN_RMS_TOLERANCE: f64 = 1e-6;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long = "service", value_parser = parse_service)]
    services: Vec<ServiceTarget>,
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

    let mut failures = Vec::new();
    for target in args.services {
        print!("{} ... ", target.name);
        match run_service(&target).await {
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

async fn run_service(target: &ServiceTarget) -> anyhow::Result<()> {
    wait_until_ready(target).await?;
    partial_schema_and_golden(target)
        .await
        .context("partial schema and golden stub")?;
    invalid_start_closes(target)
        .await
        .context("invalid start close code")?;
    invalid_frame_closes(target)
        .await
        .context("invalid frame close code")?;
    flush_cadence(target).await.context("flush cadence")?;
    normal_close(target).await.context("normal close")?;
    Ok(())
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

async fn partial_schema_and_golden(target: &ServiceTarget) -> anyhow::Result<()> {
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
        (partial.rms - GOLDEN_ONE_FRAME.rms).abs() <= GOLDEN_RMS_TOLERANCE,
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

    let _ = socket.send(Message::Close(None)).await;
    Ok(())
}

async fn invalid_start_closes(target: &ServiceTarget) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    socket
        .send(Message::Text("not-json".into()))
        .await
        .context("send invalid start")?;
    expect_close_code(&mut socket, 1002, CLOSE_TIMEOUT).await
}

async fn invalid_frame_closes(target: &ServiceTarget) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    socket
        .send(Message::Binary(vec![0_u8; 10].into()))
        .await
        .context("send invalid binary frame")?;
    expect_close_code(&mut socket, 1003, CLOSE_TIMEOUT).await
}

async fn flush_cadence(target: &ServiceTarget) -> anyhow::Result<()> {
    let mut socket = connect(target).await?;
    send_start(&mut socket).await?;
    let (mut write, mut read) = socket.split();
    let started = Instant::now();
    let stop_sending = started + Duration::from_millis(3_250);
    let deadline = started + Duration::from_secs(7);
    let mut next_frame = started;
    let mut seq = 1_u64;
    let mut partial_times = Vec::new();

    loop {
        if partial_times.len() >= 3 && Instant::now() >= stop_sending {
            break;
        }

        tokio::select! {
            () = sleep_until(next_frame), if Instant::now() < stop_sending => {
                write
                    .send(Message::Binary(frame_payload(0, seq).into()))
                    .await
                    .context("send cadence frame")?;
                seq += 1;
                next_frame += FRAME_INTERVAL;
            }
            message = read.next() => {
                let Some(message) = message else {
                    anyhow::bail!("socket closed before cadence partials");
                };
                match message.context("read cadence message")? {
                    Message::Text(text) => {
                        let partial = expect_partial(&text)
                            .context("decode cadence message")?;
                        partial.validate()?;
                        partial_times.push(Instant::now());
                    }
                    Message::Close(frame) => {
                        anyhow::bail!("server closed during cadence test: {frame:?}");
                    }
                    _ => {}
                }
            }
            () = sleep_until(deadline) => {
                anyhow::bail!("timed out waiting for cadence partials");
            }
        }
    }

    ensure!(
        partial_times.len() >= 3,
        "expected at least 3 partials, got {}",
        partial_times.len()
    );
    for window in partial_times.windows(2) {
        let interval = window[1].saturating_duration_since(window[0]);
        ensure!(
            interval >= FLUSH_INTERVAL.saturating_sub(Duration::from_millis(250)),
            "partial interval below tolerance: {interval:?}"
        );
        ensure!(
            interval <= FLUSH_INTERVAL + Duration::from_millis(500),
            "partial interval above tolerance: {interval:?}"
        );
    }
    ensure!(
        partial_times[1].saturating_duration_since(partial_times[0])
            <= FLUSH_INTERVAL + Duration::from_millis(250),
        "first cadence interval too wide"
    );

    let _ = write.send(Message::Close(None)).await;
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
