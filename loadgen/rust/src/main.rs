use std::{
    fs::File,
    future::Future,
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use anyhow::Context;
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use hdrhistogram::Histogram;
use serde::Serialize;
use stt_loadgen::protocol::{FRAME_INTERVAL, ServerMessage, StartMessage, frame_payload};
use tokio::{
    sync::mpsc,
    time::{Instant, sleep_until, timeout},
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{Error as WsError, Message},
};
use tracing::warn;
use tracing_subscriber::{EnvFilter, fmt};

const DEFAULT_CONNECT_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_SEND_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_CLOSE_GRACE_MS: u64 = 5_000;
const DEFAULT_SESSION_GRACE_SECS: u64 = 15;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long)]
    url: String,
    #[arg(long)]
    sessions: usize,
    #[arg(long, default_value_t = 15)]
    warmup_secs: u64,
    #[arg(long, default_value_t = 90)]
    measure_secs: u64,
    #[arg(long, default_value_t = 0)]
    ramp_up_secs: u64,
    #[arg(long, default_value_t = 0)]
    session_start_spread_ms: u64,
    #[arg(long, default_value_t = 1)]
    repeat: u32,
    #[arg(long, default_value_t = DEFAULT_CONNECT_TIMEOUT_MS)]
    connect_timeout_ms: u64,
    #[arg(long, default_value_t = DEFAULT_SEND_TIMEOUT_MS)]
    send_timeout_ms: u64,
    #[arg(long, default_value_t = DEFAULT_CLOSE_GRACE_MS)]
    close_grace_ms: u64,
    #[arg(long, default_value_t = DEFAULT_SESSION_GRACE_SECS)]
    session_grace_secs: u64,
    #[arg(long)]
    samples_out: Option<PathBuf>,
    #[arg(long)]
    service_name: Option<String>,
}

#[derive(Debug, Clone, Copy)]
struct TimeoutConfig {
    connect: Duration,
    send: Duration,
    close_grace: Duration,
    session: Duration,
}

#[derive(Debug, Default)]
struct TimeoutCounters {
    connect: AtomicU64,
    send: AtomicU64,
    close: AtomicU64,
    session: AtomicU64,
}

impl TimeoutCounters {
    fn increment(&self, kind: TimeoutKind) {
        match kind {
            TimeoutKind::Connect => &self.connect,
            TimeoutKind::Send => &self.send,
            TimeoutKind::Close => &self.close,
            TimeoutKind::Session => &self.session,
        }
        .fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> TimeoutOutput {
        TimeoutOutput {
            connect: self.connect.load(Ordering::Relaxed),
            send: self.send.load(Ordering::Relaxed),
            close: self.close.load(Ordering::Relaxed),
            session: self.session.load(Ordering::Relaxed),
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum TimeoutKind {
    Connect,
    Send,
    Close,
    Session,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum InboundState {
    Open,
    Closed,
}

#[derive(Debug, Default, Serialize)]
struct TimeoutOutput {
    connect: u64,
    send: u64,
    close: u64,
    session: u64,
}

#[derive(Debug)]
struct Sample {
    session_id: usize,
    oldest_frame_seq: u64,
    newest_frame_seq: u64,
    frames: u64,
    transcript: String,
    audio_bytes: u64,
    newest_us: u64,
    oldest_us: u64,
    flush_lateness_us: u64,
    received_us: u64,
}

#[derive(Debug, Serialize)]
struct Output {
    url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    service_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    samples_file: Option<String>,
    sessions: usize,
    repeat: u32,
    warmup_secs: u64,
    measure_secs: u64,
    ramp_up_secs: u64,
    session_start_spread_ms: u64,
    partials: u64,
    protocol_errors: u64,
    inference_errors: u64,
    timeouts: TimeoutOutput,
    newest_frame_to_partial_latency: Percentiles,
    oldest_frame_to_partial_latency: Percentiles,
    flush_lateness: Percentiles,
}

#[derive(Debug, Serialize)]
struct Percentiles {
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
    p999_ms: f64,
    max_ms: f64,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("warn".parse().unwrap()))
        .init();

    let args = Args::parse();
    let protocol_errors = Arc::new(AtomicU64::new(0));
    let inference_errors = Arc::new(AtomicU64::new(0));
    let timeout_counters = Arc::new(TimeoutCounters::default());
    let ramp_up = Duration::from_secs(args.ramp_up_secs);
    let session_start_spread = Duration::from_millis(args.session_start_spread_ms);
    let pre_measure_delay = measure_start_delay(
        Duration::from_secs(args.warmup_secs),
        ramp_up,
        session_start_spread,
    );
    let timeouts = TimeoutConfig {
        connect: Duration::from_millis(args.connect_timeout_ms),
        send: Duration::from_millis(args.send_timeout_ms),
        close_grace: Duration::from_millis(args.close_grace_ms),
        session: pre_measure_delay
            + Duration::from_secs(args.measure_secs)
            + Duration::from_secs(args.session_grace_secs),
    };
    let (sample_tx, mut sample_rx) = mpsc::channel::<Sample>(8192);
    let run_start = Instant::now();
    let measure_start = run_start + pre_measure_delay;
    let end_at = measure_start + Duration::from_secs(args.measure_secs);

    for session_id in 0..args.sessions {
        let tx = sample_tx.clone();
        let errors = Arc::clone(&protocol_errors);
        let inference_err_counter = Arc::clone(&inference_errors);
        let counters = Arc::clone(&timeout_counters);
        let url = args.url.clone();
        let session_start_at = run_start
            + session_start_delay(session_id, args.sessions, ramp_up, session_start_spread);
        tokio::spawn(async move {
            match timeout(
                timeouts.session,
                run_session(
                    session_id,
                    &url,
                    session_start_at,
                    measure_start,
                    end_at,
                    tx,
                    timeouts,
                    counters.clone(),
                    inference_err_counter,
                ),
            )
            .await
            {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    errors.fetch_add(1, Ordering::Relaxed);
                    warn!(session_id, %error, "session failed");
                }
                Err(_elapsed) => {
                    counters.increment(TimeoutKind::Session);
                    errors.fetch_add(1, Ordering::Relaxed);
                    warn!(session_id, "session timed out");
                }
            }
        });
    }
    drop(sample_tx);

    let mut newest_hist = Histogram::<u64>::new_with_max(60_000_000, 3)?;
    let mut oldest_hist = Histogram::<u64>::new_with_max(60_000_000, 3)?;
    let mut flush_hist = Histogram::<u64>::new_with_max(60_000_000, 3)?;
    let mut partials = 0_u64;
    let mut samples_writer = match &args.samples_out {
        Some(path) => {
            if let Some(parent) = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
            {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("create samples output directory {parent:?}"))?;
            }
            let file =
                File::create(path).with_context(|| format!("create samples file {path:?}"))?;
            let mut writer = BufWriter::new(file);
            write_samples_csv_header(&mut writer).context("write samples csv header")?;
            Some(writer)
        }
        None => None,
    };

    while let Some(sample) = sample_rx.recv().await {
        if let Some(writer) = samples_writer.as_mut() {
            write_sample_csv_row(writer, partials, &sample).context("write samples csv row")?;
        }
        partials += 1;
        newest_hist.record(sample.newest_us).ok();
        oldest_hist.record(sample.oldest_us).ok();
        flush_hist.record(sample.flush_lateness_us).ok();
    }
    if let Some(mut writer) = samples_writer {
        writer.flush().context("flush samples csv")?;
    }

    let output = Output {
        url: args.url,
        service_name: args.service_name,
        samples_file: args
            .samples_out
            .as_ref()
            .map(|path| path.display().to_string()),
        sessions: args.sessions,
        repeat: args.repeat,
        warmup_secs: args.warmup_secs,
        measure_secs: args.measure_secs,
        ramp_up_secs: args.ramp_up_secs,
        session_start_spread_ms: args.session_start_spread_ms,
        partials,
        protocol_errors: protocol_errors.load(Ordering::Relaxed),
        inference_errors: inference_errors.load(Ordering::Relaxed),
        timeouts: timeout_counters.snapshot(),
        newest_frame_to_partial_latency: percentiles(&newest_hist),
        oldest_frame_to_partial_latency: percentiles(&oldest_hist),
        flush_lateness: percentiles(&flush_hist),
    };

    println!("{}", serde_json::to_string_pretty(&output)?);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_session(
    session_id: usize,
    url: &str,
    session_start_at: Instant,
    measure_start: Instant,
    end_at: Instant,
    sample_tx: mpsc::Sender<Sample>,
    timeouts: TimeoutConfig,
    timeout_counters: Arc<TimeoutCounters>,
    inference_errors: Arc<AtomicU64>,
) -> anyhow::Result<()> {
    sleep_until(session_start_at).await;
    let (ws, _) = timed(
        timeouts.connect,
        async {
            connect_async(url)
                .await
                .with_context(|| format!("connect {url}"))
        },
        &timeout_counters,
        TimeoutKind::Connect,
        "connect",
    )
    .await?;
    let (mut write, mut read) = ws.split();
    let start = serde_json::to_string(&StartMessage::Start)?;
    timed(
        timeouts.send,
        async {
            write
                .send(Message::Text(start.into()))
                .await
                .context("send start")
        },
        &timeout_counters,
        TimeoutKind::Send,
        "send start",
    )
    .await?;

    let mut sent_times = Vec::<Instant>::new();
    let mut seq = 0_u64;
    let mut next_tick = Instant::now();
    while Instant::now() < end_at {
        tokio::select! {
            () = sleep_until(next_tick), if Instant::now() < end_at => {
                seq += 1;
                let now = Instant::now();
                sent_times.push(now);
                let payload = frame_payload(session_id, seq);
                timed(
                    timeouts.send,
                    async {
                        write
                            .send(Message::Binary(payload.into()))
                            .await
                            .context("send pcm frame")
                    },
                    &timeout_counters,
                    TimeoutKind::Send,
                    "send pcm frame",
                )
                .await?;
                next_tick += FRAME_INTERVAL;
            }
            message = read.next() => {
                if process_inbound(
                    session_id,
                    message,
                    measure_start,
                    end_at,
                    &sent_times,
                    &sample_tx,
                    &inference_errors,
                )
                    .await?
                    == InboundState::Closed
                {
                    anyhow::bail!("websocket closed before send loop finished");
                }
            }
        }
    }

    timed(
        timeouts.send,
        async { write.send(Message::Close(None)).await.context("send close") },
        &timeout_counters,
        TimeoutKind::Send,
        "send close",
    )
    .await?;

    let close_deadline = Instant::now() + timeouts.close_grace;
    loop {
        tokio::select! {
            message = read.next() => {
                if process_inbound(
                    session_id,
                    message,
                    measure_start,
                    end_at,
                    &sent_times,
                    &sample_tx,
                    &inference_errors,
                )
                    .await?
                    == InboundState::Closed
                {
                    break;
                }
            }
            () = sleep_until(close_deadline) => {
                timeout_counters.increment(TimeoutKind::Close);
                anyhow::bail!(
                    "receiver did not finish within close grace {:?}",
                    timeouts.close_grace
                );
            }
        }
    }
    Ok(())
}

fn measure_start_delay(
    warmup: Duration,
    ramp_up: Duration,
    session_start_spread: Duration,
) -> Duration {
    ramp_up + session_start_spread + warmup
}

fn session_start_delay(
    session_id: usize,
    sessions: usize,
    ramp_up: Duration,
    session_start_spread: Duration,
) -> Duration {
    if sessions == 0 {
        return Duration::ZERO;
    }
    scale_duration(ramp_up, session_id, sessions)
        + scale_duration(session_start_spread, session_id, sessions)
}

fn scale_duration(duration: Duration, numerator: usize, denominator: usize) -> Duration {
    if duration.is_zero() || numerator == 0 || denominator == 0 {
        return Duration::ZERO;
    }
    let nanos = duration.as_nanos().saturating_mul(numerator as u128) / denominator as u128;
    Duration::from_nanos(nanos.min(u64::MAX as u128) as u64)
}

async fn process_inbound(
    session_id: usize,
    message: Option<Result<Message, WsError>>,
    measure_start: Instant,
    end_at: Instant,
    sent_times: &[Instant],
    sample_tx: &mpsc::Sender<Sample>,
    inference_errors: &Arc<AtomicU64>,
) -> anyhow::Result<InboundState> {
    let message = match message {
        Some(Ok(Message::Close(_))) => return Ok(InboundState::Closed),
        Some(Ok(message)) => message,
        Some(Err(WsError::ConnectionClosed | WsError::AlreadyClosed)) | None => {
            return Ok(InboundState::Closed);
        }
        Some(Err(error)) => return Err(error).context("read websocket message"),
    };

    let Message::Text(text) = message else {
        return Ok(InboundState::Open);
    };
    let server_message: ServerMessage =
        serde_json::from_str(&text).context("decode server message")?;
    let partial = match server_message {
        ServerMessage::Partial(partial) => partial,
        ServerMessage::Error(error) => {
            inference_errors.fetch_add(1, Ordering::Relaxed);
            warn!(
                session_id,
                stage = %error.stage,
                kind = %error.kind,
                oldest = error.oldest_frame_seq,
                newest = error.newest_frame_seq,
                retryable = error.retryable,
                "gateway error frame: {}",
                error.message,
            );
            return Ok(InboundState::Open);
        }
    };
    partial.validate().context("validate partial")?;

    let now = Instant::now();
    if now < measure_start || now > end_at {
        return Ok(InboundState::Open);
    }

    let newest_sent = sent_times
        .get(partial.newest_frame_seq.saturating_sub(1) as usize)
        .copied();
    let oldest_sent = sent_times
        .get(partial.oldest_frame_seq.saturating_sub(1) as usize)
        .copied();

    if let (Some(newest_sent), Some(oldest_sent)) = (newest_sent, oldest_sent) {
        let flush_lateness_us = (partial.flush_lateness_ms.max(0.0) * 1000.0).round() as u64;
        sample_tx
            .send(Sample {
                session_id,
                oldest_frame_seq: partial.oldest_frame_seq,
                newest_frame_seq: partial.newest_frame_seq,
                frames: partial.frames,
                transcript: partial.transcript,
                audio_bytes: partial.audio_bytes,
                newest_us: now.saturating_duration_since(newest_sent).as_micros() as u64,
                oldest_us: now.saturating_duration_since(oldest_sent).as_micros() as u64,
                flush_lateness_us,
                received_us: now.saturating_duration_since(measure_start).as_micros() as u64,
            })
            .await
            .context("send sample")?;
    }
    Ok(InboundState::Open)
}

async fn timed<T, F>(
    duration: Duration,
    future: F,
    timeout_counters: &TimeoutCounters,
    kind: TimeoutKind,
    label: &'static str,
) -> anyhow::Result<T>
where
    F: Future<Output = anyhow::Result<T>>,
{
    match timeout(duration, future).await {
        Ok(result) => result,
        Err(_elapsed) => {
            timeout_counters.increment(kind);
            anyhow::bail!("{label} timed out after {duration:?}");
        }
    }
}

fn percentiles(histogram: &Histogram<u64>) -> Percentiles {
    let micros_to_ms = |micros: u64| micros as f64 / 1000.0;
    if histogram.is_empty() {
        return Percentiles {
            p50_ms: 0.0,
            p95_ms: 0.0,
            p99_ms: 0.0,
            p999_ms: 0.0,
            max_ms: 0.0,
        };
    }
    Percentiles {
        p50_ms: micros_to_ms(histogram.value_at_quantile(0.50)),
        p95_ms: micros_to_ms(histogram.value_at_quantile(0.95)),
        p99_ms: micros_to_ms(histogram.value_at_quantile(0.99)),
        p999_ms: micros_to_ms(histogram.value_at_quantile(0.999)),
        max_ms: micros_to_ms(histogram.max()),
    }
}

fn write_samples_csv_header(writer: &mut impl Write) -> std::io::Result<()> {
    writeln!(
        writer,
        "sample_index,session_id,oldest_frame_seq,newest_frame_seq,frames,\
transcript,audio_bytes,\
newest_latency_ms,oldest_latency_ms,flush_lateness_ms,received_ms"
    )
}

fn write_sample_csv_row(
    writer: &mut impl Write,
    sample_index: u64,
    sample: &Sample,
) -> std::io::Result<()> {
    write!(
        writer,
        "{sample_index},{},{},{},{},{},{},",
        sample.session_id,
        sample.oldest_frame_seq,
        sample.newest_frame_seq,
        sample.frames,
        sample.transcript,
        sample.audio_bytes,
    )?;
    write_millis(writer, sample.newest_us)?;
    writer.write_all(b",")?;
    write_millis(writer, sample.oldest_us)?;
    writer.write_all(b",")?;
    write_millis(writer, sample.flush_lateness_us)?;
    writer.write_all(b",")?;
    write_millis(writer, sample.received_us)?;
    writer.write_all(b"\n")
}

fn write_millis(writer: &mut impl Write, micros: u64) -> std::io::Result<()> {
    write!(writer, "{}.{:03}", micros / 1000, micros % 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_sample_csv_header_and_row() {
        let sample = Sample {
            session_id: 7,
            oldest_frame_seq: 2,
            newest_frame_seq: 4,
            frames: 3,
            transcript: "now".to_string(),
            audio_bytes: 1920,
            newest_us: 12_345,
            oldest_us: 67_890,
            flush_lateness_us: 1_200,
            received_us: 250_500,
        };
        let mut output = Vec::new();

        write_samples_csv_header(&mut output).expect("write header");
        write_sample_csv_row(&mut output, 0, &sample).expect("write row");

        let csv = String::from_utf8(output).expect("utf8 csv");
        assert_eq!(
            csv,
            "sample_index,session_id,oldest_frame_seq,newest_frame_seq,frames,transcript,audio_bytes,newest_latency_ms,oldest_latency_ms,flush_lateness_ms,received_ms\n\
0,7,2,4,3,now,1920,12.345,67.890,1.200,250.500\n"
        );
    }

    #[test]
    fn computes_linear_ramp_and_start_spread_delay() {
        let ramp = Duration::from_secs(8);
        let spread = Duration::from_millis(250);

        let delays = (0..4)
            .map(|session_id| session_start_delay(session_id, 4, ramp, spread).as_millis())
            .collect::<Vec<_>>();

        assert_eq!(delays, vec![0, 2062, 4125, 6187]);
    }

    #[test]
    fn computes_measure_start_after_all_sessions_are_admitted() {
        let warmup = Duration::from_secs(15);
        let ramp = Duration::from_secs(30);
        let spread = Duration::from_millis(250);

        assert_eq!(
            measure_start_delay(warmup, ramp, spread),
            Duration::from_millis(45_250)
        );
    }
}
