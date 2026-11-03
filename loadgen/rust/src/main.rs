use std::{
    collections::BTreeMap,
    fs::File,
    future::Future,
    io::{BufWriter, IsTerminal, Write},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc::{SyncSender, TrySendError, sync_channel},
    },
    thread::JoinHandle,
    time::Duration,
};

use anyhow::Context;
use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use hdrhistogram::Histogram;
use serde::Serialize;
use stt_loadgen::{
    protocol::{
        ErrorMessage, FRAME_INTERVAL, PartialMessage, ServerMessage, StartMessage, frame_payload,
    },
    verify::{Continuity, ExpectedConfig, Mismatch, MismatchKind, check_tail, verify_partial},
};
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
    /// Recompute the expected stub output for every Nth measured partial per
    /// session (1 = all, 0 = off). Continuity is always checked.
    #[arg(long, default_value_t = 1)]
    verify_every: u64,
    /// `cpu_passes` every partial must echo (gateway `CPU_PASSES`).
    #[arg(long, default_value_t = ExpectedConfig::default().cpu_passes)]
    expect_cpu_passes: u32,
    /// `model_delay_ms` every partial must echo (gateway `MODEL_DELAY_MS`).
    #[arg(long, default_value_t = ExpectedConfig::default().model_delay_ms)]
    expect_model_delay_ms: u64,
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

const MAX_INFERENCE_ERROR_SAMPLES: usize = 5;

#[derive(Debug, Default)]
struct InferenceErrorDetails {
    counts: BTreeMap<(String, String), u64>,
    samples: Vec<InferenceErrorSample>,
}

impl InferenceErrorDetails {
    fn record(&mut self, error: &ErrorMessage) {
        let key = (error.stage.clone(), error.kind.clone());
        *self.counts.entry(key).or_default() += 1;

        let sample = InferenceErrorSample::from(error);
        if self.samples.len() < MAX_INFERENCE_ERROR_SAMPLES && !self.samples.contains(&sample) {
            self.samples.push(sample);
        }
    }

    fn snapshot(&self) -> InferenceErrorSnapshot {
        let counts = self
            .counts
            .iter()
            .map(|((stage, kind), count)| InferenceErrorCount {
                stage: stage.clone(),
                kind: kind.clone(),
                count: *count,
            })
            .collect();
        InferenceErrorSnapshot {
            counts,
            samples: self.samples.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
struct InferenceErrorSnapshot {
    counts: Vec<InferenceErrorCount>,
    samples: Vec<InferenceErrorSample>,
}

#[derive(Debug, Serialize)]
struct InferenceErrorCount {
    stage: String,
    kind: String,
    count: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct InferenceErrorSample {
    stage: String,
    kind: String,
    message: String,
    inference_status: Option<u16>,
    retryable: bool,
}

impl From<&ErrorMessage> for InferenceErrorSample {
    fn from(error: &ErrorMessage) -> Self {
        Self {
            stage: error.stage.clone(),
            kind: error.kind.clone(),
            message: error.message.clone(),
            inference_status: error.inference_status,
            retryable: error.retryable,
        }
    }
}

const MAX_CORRECTNESS_ERROR_SAMPLES: usize = 5;
const MAX_CORRECTNESS_WARNINGS: u64 = 20;

/// Run-wide correctness accounting. Shared by all session tasks; the mutex is
/// only taken when a response is wrong.
#[derive(Debug)]
struct Correctness {
    expected: ExpectedConfig,
    verify_every: u64,
    /// Responses (partials or error frames) with at least one mismatch.
    errors: AtomicU64,
    /// Partials whose values were recomputed and compared.
    verified: AtomicU64,
    /// Partials selected for value verification that were not verified
    /// because the verifier queue was full (continuity was still checked).
    verify_dropped: AtomicU64,
    details: Mutex<CorrectnessDetails>,
}

#[derive(Debug, Default)]
struct CorrectnessDetails {
    counts: BTreeMap<MismatchKind, u64>,
    samples: Vec<CorrectnessErrorSample>,
}

#[derive(Debug, Clone, Serialize)]
struct CorrectnessErrorSample {
    session_id: usize,
    message_type: &'static str,
    oldest_frame_seq: u64,
    newest_frame_seq: u64,
    kind: &'static str,
    detail: String,
}

#[derive(Debug, Serialize)]
struct CorrectnessErrorCount {
    kind: &'static str,
    count: u64,
}

impl Correctness {
    fn new(expected: ExpectedConfig, verify_every: u64) -> Self {
        Self {
            expected,
            verify_every,
            errors: AtomicU64::new(0),
            verified: AtomicU64::new(0),
            verify_dropped: AtomicU64::new(0),
            details: Mutex::new(CorrectnessDetails::default()),
        }
    }

    fn record(
        &self,
        session_id: usize,
        message_type: &'static str,
        oldest: u64,
        newest: u64,
        mismatches: &[Mismatch],
    ) {
        let Some(first) = mismatches.first() else {
            return;
        };
        let previous = self.errors.fetch_add(1, Ordering::Relaxed);
        // A systematically broken gateway fails every partial; log only the
        // first few (the summary JSON carries counts and samples).
        if previous < MAX_CORRECTNESS_WARNINGS {
            warn!(
                session_id,
                oldest, newest, message_type, "incorrect response: {first}"
            );
        }
        let mut details = self
            .details
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for mismatch in mismatches {
            *details.counts.entry(mismatch.kind).or_default() += 1;
        }
        if details.samples.len() < MAX_CORRECTNESS_ERROR_SAMPLES {
            details.samples.push(CorrectnessErrorSample {
                session_id,
                message_type,
                oldest_frame_seq: oldest,
                newest_frame_seq: newest,
                kind: first.kind.as_str(),
                detail: mismatches
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("; "),
            });
        }
    }

    fn snapshot(&self) -> (Vec<CorrectnessErrorCount>, Vec<CorrectnessErrorSample>) {
        let details = self
            .details
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let counts = details
            .counts
            .iter()
            .map(|(kind, count)| CorrectnessErrorCount {
                kind: kind.as_str(),
                count: *count,
            })
            .collect();
        (counts, details.samples.clone())
    }
}

/// Per-session verification state, owned by the session task.
#[derive(Debug, Default)]
struct SessionCheck {
    continuity: Continuity,
    measured_partials: u64,
}

/// Bound on queued verifications. At ~100 µs per 50-frame partial one
/// verifier thread sustains ~10k partials/s; this absorbs a few seconds of
/// burst at 4000 sessions before dropping (counted, never blocking).
const VERIFY_QUEUE_CAPACITY: usize = 16_384;

/// A measured partial selected for value verification, plus any mismatches
/// already found inline (continuity), so the response is recorded once.
#[derive(Debug)]
struct VerifyJob {
    session_id: usize,
    partial: PartialMessage,
    inline: Vec<Mismatch>,
}

/// Recomputes expected stub output off the receive path. `verify_partial`
/// costs ~100 µs per 50-frame partial; inline on a tokio worker it would
/// delay timestamping every other session's messages on that thread.
struct Verifier {
    tx: SyncSender<VerifyJob>,
    thread: JoinHandle<()>,
}

impl Verifier {
    fn spawn(correctness: Arc<Correctness>, capacity: usize) -> anyhow::Result<Self> {
        let (tx, rx) = sync_channel::<VerifyJob>(capacity);
        let thread = std::thread::Builder::new()
            .name("stt-verify".to_string())
            .spawn(move || {
                // One scratch buffer for the whole run (a 50-frame flush is
                // 32 KB of rebuilt PCM).
                let mut scratch = Vec::new();
                for job in rx {
                    let mut mismatches = job.inline;
                    mismatches.extend(verify_partial(
                        job.session_id,
                        &job.partial,
                        correctness.expected,
                        &mut scratch,
                    ));
                    correctness.verified.fetch_add(1, Ordering::Relaxed);
                    correctness.record(
                        job.session_id,
                        "partial",
                        job.partial.oldest_frame_seq,
                        job.partial.newest_frame_seq,
                        &mismatches,
                    );
                }
            })
            .context("spawn verifier thread")?;
        Ok(Self { tx, thread })
    }

    fn sender(&self) -> SyncSender<VerifyJob> {
        self.tx.clone()
    }

    /// Drop this handle's sender and wait for the queue to drain. Returns
    /// once every other sender (one per session task) is gone too, so all
    /// correctness counters are final.
    fn finish(self) -> anyhow::Result<()> {
        drop(self.tx);
        self.thread
            .join()
            .map_err(|_panic| anyhow::anyhow!("verifier thread panicked"))
    }
}

/// Hand `job` to the verifier without blocking. If the queue is full, count
/// the drop and record the inline (continuity) mismatches here instead.
fn submit_verify(correctness: &Correctness, verify_tx: &SyncSender<VerifyJob>, job: VerifyJob) {
    match verify_tx.try_send(job) {
        Ok(()) => {}
        Err(TrySendError::Full(job) | TrySendError::Disconnected(job)) => {
            correctness.verify_dropped.fetch_add(1, Ordering::Relaxed);
            correctness.record(
                job.session_id,
                "partial",
                job.partial.oldest_frame_seq,
                job.partial.newest_frame_seq,
                &job.inline,
            );
        }
    }
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
    /// Failed sessions, one per session, *including* sessions that failed on a
    /// timeout (see `record_session_outcome`). Disjoint from `inference_errors`.
    protocol_errors: u64,
    /// Gateway `error` frames received; the session keeps running.
    inference_errors: u64,
    inference_error_counts: Vec<InferenceErrorCount>,
    inference_error_samples: Vec<InferenceErrorSample>,
    /// Measured responses that failed continuity or expected-value checks,
    /// plus one per session whose unreported tail exceeded the tolerance
    /// (`missing_tail`).
    correctness_errors: u64,
    correctness_error_counts: Vec<CorrectnessErrorCount>,
    correctness_error_samples: Vec<CorrectnessErrorSample>,
    verify_every: u64,
    verified_partials: u64,
    /// Partials selected for value verification but skipped because the
    /// verifier queue was full. Non-zero means `verified_partials` undercounts
    /// the requested sample; continuity was still checked for all of them.
    verify_dropped: u64,
    /// Cause breakdown for the subset of `protocol_errors` that were timeouts.
    /// Already included in `protocol_errors`; do not add them again.
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
    // Logs go to stderr: stdout carries only the summary JSON, which callers
    // pipe into `eval_slo.py` / `jq` / `tee` (run_point.sh splits the two).
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("warn".parse().unwrap()))
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .init();

    let args = Args::parse();
    let protocol_errors = Arc::new(AtomicU64::new(0));
    let inference_errors = Arc::new(AtomicU64::new(0));
    let inference_error_details = Arc::new(Mutex::new(InferenceErrorDetails::default()));
    let timeout_counters = Arc::new(TimeoutCounters::default());
    let correctness = Arc::new(Correctness::new(
        ExpectedConfig {
            cpu_passes: args.expect_cpu_passes,
            model_delay_ms: args.expect_model_delay_ms,
        },
        args.verify_every,
    ));
    let verifier = Verifier::spawn(Arc::clone(&correctness), VERIFY_QUEUE_CAPACITY)?;
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
        let inference_err_details = Arc::clone(&inference_error_details);
        let counters = Arc::clone(&timeout_counters);
        let session_correctness = Arc::clone(&correctness);
        let verify_tx = verifier.sender();
        let url = args.url.clone();
        let session_start_at = run_start
            + session_start_delay(session_id, args.sessions, ramp_up, session_start_spread);
        tokio::spawn(async move {
            let outcome = timeout(
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
                    inference_err_details,
                    session_correctness,
                    verify_tx,
                ),
            )
            .await
            .map_err(|_elapsed| ());
            record_session_outcome(session_id, outcome, &errors, &counters);
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
    // Every session task has exited (sample_rx closed), so their verifier
    // senders are gone; drain the queue before reading correctness counters.
    verifier.finish()?;

    let inference_error_snapshot = inference_error_details
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .snapshot();
    let (correctness_error_counts, correctness_error_samples) = correctness.snapshot();
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
        inference_error_counts: inference_error_snapshot.counts,
        inference_error_samples: inference_error_snapshot.samples,
        correctness_errors: correctness.errors.load(Ordering::Relaxed),
        correctness_error_counts,
        correctness_error_samples,
        verify_every: args.verify_every,
        verified_partials: correctness.verified.load(Ordering::Relaxed),
        verify_dropped: correctness.verify_dropped.load(Ordering::Relaxed),
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
    inference_error_details: Arc<Mutex<InferenceErrorDetails>>,
    correctness: Arc<Correctness>,
    verify_tx: SyncSender<VerifyJob>,
) -> anyhow::Result<()> {
    sleep_until(session_start_at).await;
    let mut check = SessionCheck::default();
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
                // Latency is measured from the *scheduled* send time, not the
                // actual one: if this task wakes late (busy loadgen host), that
                // lag is real delay the audio would have suffered and must not
                // be dropped from the measurement (coordinated omission).
                // Sends stay on the fixed `next_tick` timeline and catch up.
                sent_times.push(next_tick);
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
                    &inference_error_details,
                    &correctness,
                    &verify_tx,
                    &mut check,
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
                    &inference_error_details,
                    &correctness,
                    &verify_tx,
                    &mut check,
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
    check_session_tail(session_id, &sent_times, measure_start, &check, &correctness);
    Ok(())
}

/// Continuity only fires on the *next* response, so dropped final
/// partial(s) would go unnoticed. Once the session has stopped receiving,
/// flag a tail of sent-but-never-reported frames longer than a correct
/// gateway could owe at close (`verify::TAIL_TOLERANCE_FRAMES`). Only
/// sessions that sent audio inside the measured window are checked.
fn check_session_tail(
    session_id: usize,
    sent_times: &[Instant],
    measure_start: Instant,
    check: &SessionCheck,
    correctness: &Correctness,
) {
    if sent_times.last().is_none_or(|&last| last < measure_start) {
        return;
    }
    let sent = sent_times.len() as u64;
    let reported = check.continuity.last_newest();
    if let Some(mismatch) = check_tail(sent, reported) {
        correctness.record(session_id, "session_end", reported + 1, sent, &[mismatch]);
    }
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

#[allow(clippy::too_many_arguments)]
async fn process_inbound(
    session_id: usize,
    message: Option<Result<Message, WsError>>,
    measure_start: Instant,
    end_at: Instant,
    sent_times: &[Instant],
    sample_tx: &mpsc::Sender<Sample>,
    inference_errors: &Arc<AtomicU64>,
    inference_error_details: &Arc<Mutex<InferenceErrorDetails>>,
    correctness: &Correctness,
    verify_tx: &SyncSender<VerifyJob>,
    check: &mut SessionCheck,
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
    let now = Instant::now();
    let measured = now >= measure_start && now <= end_at;
    let partial = match server_message {
        ServerMessage::Partial(partial) => partial,
        ServerMessage::Error(error) => {
            // Error frames consume their batch's range (gateways drain and
            // do not retry), so they must tile the sequence like partials.
            let gap = check
                .continuity
                .observe(error.oldest_frame_seq, error.newest_frame_seq);
            if measured && let Some(mismatch) = gap {
                correctness.record(
                    session_id,
                    "error",
                    error.oldest_frame_seq,
                    error.newest_frame_seq,
                    &[mismatch],
                );
            }
            inference_errors.fetch_add(1, Ordering::Relaxed);
            inference_error_details
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .record(&error);
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
    // Observe the range before validating: a partial that fails some other
    // check still consumed its frames, so the next one must not also report
    // a gap. (`observe` ignores malformed ranges.)
    let continuity = check
        .continuity
        .observe(partial.oldest_frame_seq, partial.newest_frame_seq);
    partial.validate().context("validate partial")?;
    if !measured {
        return Ok(InboundState::Open);
    }
    let mut inline: Vec<Mismatch> = continuity.into_iter().collect();
    let sent = sent_times.len() as u64;
    let unsent = partial.newest_frame_seq > sent;
    if unsent {
        inline.push(Mismatch {
            kind: MismatchKind::UnsentFrame,
            detail: format!(
                "newest_frame_seq={} but only {sent} frames sent",
                partial.newest_frame_seq
            ),
        });
    }

    // Latency first, from the timestamp taken right after decode.
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
                transcript: partial.transcript.clone(),
                audio_bytes: partial.audio_bytes,
                newest_us: now.saturating_duration_since(newest_sent).as_micros() as u64,
                oldest_us: now.saturating_duration_since(oldest_sent).as_micros() as u64,
                flush_lateness_us,
                received_us: now.saturating_duration_since(measure_start).as_micros() as u64,
            })
            .await
            .context("send sample")?;
    }

    // Value verification runs on the verifier thread; only O(1) work here.
    let selected = !unsent && correctness.verify_every > 0 && {
        let nth = check
            .measured_partials
            .is_multiple_of(correctness.verify_every);
        check.measured_partials += 1;
        nth
    };
    if selected {
        submit_verify(
            correctness,
            verify_tx,
            VerifyJob {
                session_id,
                partial,
                inline,
            },
        );
    } else {
        correctness.record(
            session_id,
            "partial",
            partial.oldest_frame_seq,
            partial.newest_frame_seq,
            &inline,
        );
    }
    Ok(InboundState::Open)
}

/// Count one finished session. Every failed session -- whatever the cause --
/// bumps `protocol_errors` exactly once; a session that failed because of a
/// timeout additionally bumps exactly one `timeouts.*` counter (inside `timed`,
/// the close-grace arm, or here for the whole-session deadline). So
/// `timeouts.*` is a *breakdown* of a subset of `protocol_errors`, not a
/// disjoint count: the number of failed sessions is `protocol_errors`.
/// `Err(())` means the whole-session deadline elapsed.
fn record_session_outcome(
    session_id: usize,
    outcome: Result<anyhow::Result<()>, ()>,
    protocol_errors: &AtomicU64,
    timeout_counters: &TimeoutCounters,
) {
    match outcome {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            protocol_errors.fetch_add(1, Ordering::Relaxed);
            warn!(session_id, "session failed: {error:#}");
        }
        Err(()) => {
            timeout_counters.increment(TimeoutKind::Session);
            protocol_errors.fetch_add(1, Ordering::Relaxed);
            warn!(session_id, "session timed out");
        }
    }
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

    fn timeout_total(counters: &TimeoutCounters) -> u64 {
        let t = counters.snapshot();
        t.connect + t.send + t.close + t.session
    }

    #[test]
    fn clean_session_counts_nothing() {
        let (errors, counters) = (AtomicU64::new(0), TimeoutCounters::default());
        record_session_outcome(0, Ok(Ok(())), &errors, &counters);
        assert_eq!(errors.load(Ordering::Relaxed), 0);
        assert_eq!(timeout_total(&counters), 0);
    }

    #[test]
    fn non_timeout_failure_counts_only_protocol_error() {
        let (errors, counters) = (AtomicU64::new(0), TimeoutCounters::default());
        record_session_outcome(0, Ok(Err(anyhow::anyhow!("decode"))), &errors, &counters);
        assert_eq!(errors.load(Ordering::Relaxed), 1);
        assert_eq!(timeout_total(&counters), 0);
    }

    #[test]
    fn session_deadline_counts_once_in_both() {
        let (errors, counters) = (AtomicU64::new(0), TimeoutCounters::default());
        record_session_outcome(0, Err(()), &errors, &counters);
        assert_eq!(errors.load(Ordering::Relaxed), 1);
        assert_eq!(counters.snapshot().session, 1);
        assert_eq!(timeout_total(&counters), 1);
    }

    /// A connect/send timeout bumps its own counter inside `timed`, and the
    /// resulting session error then bumps `protocol_errors`: one failed session,
    /// one protocol error, one timeout -- the timeout is a subset, not extra.
    #[tokio::test]
    async fn inner_timeout_is_subset_of_protocol_errors() {
        let (errors, counters) = (AtomicU64::new(0), TimeoutCounters::default());
        let result = timed(
            Duration::from_millis(1),
            std::future::pending::<anyhow::Result<()>>(),
            &counters,
            TimeoutKind::Connect,
            "connect",
        )
        .await;
        assert!(result.is_err());
        record_session_outcome(0, Ok(result), &errors, &counters);
        assert_eq!(errors.load(Ordering::Relaxed), 1);
        assert_eq!(counters.snapshot().connect, 1);
        assert_eq!(timeout_total(&counters), 1);
    }

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
    fn records_inference_error_counts_and_samples() {
        let mut details = InferenceErrorDetails::default();
        let error = stt_loadgen::protocol::ErrorMessage {
            stage: "inference_response_parse".to_string(),
            kind: "http_4xx".to_string(),
            message: "inference returned HTTP 404".to_string(),
            oldest_frame_seq: 10,
            newest_frame_seq: 12,
            frames: 3,
            audio_bytes: 1920,
            oldest_age_ms: 1000.0,
            newest_age_ms: 0.0,
            flush_lateness_ms: 2.5,
            inference_elapsed_ms: Some(74.0),
            inflight_gateway_batches: 1,
            gateway_buffer_frames: 0,
            inference_status: Some(404),
            retryable: false,
        };

        details.record(&error);
        details.record(&error);

        let snapshot = details.snapshot();
        assert_eq!(snapshot.counts.len(), 1);
        assert_eq!(snapshot.counts[0].stage, "inference_response_parse");
        assert_eq!(snapshot.counts[0].kind, "http_4xx");
        assert_eq!(snapshot.counts[0].count, 2);
        assert_eq!(snapshot.samples.len(), 1);
        assert_eq!(snapshot.samples[0].message, "inference returned HTTP 404");
        assert_eq!(snapshot.samples[0].inference_status, Some(404));
        assert!(!snapshot.samples[0].retryable);
    }

    fn partial_text(session_id: usize, oldest: u64, newest: u64) -> Message {
        let stub =
            stt_loadgen::verify::expected_stub(session_id, oldest, newest, 4, &mut Vec::new());
        let partial = stt_loadgen::protocol::PartialMessage {
            oldest_frame_seq: oldest,
            newest_frame_seq: newest,
            frames: newest - oldest + 1,
            rms: stub.rms,
            zero_crossings: stub.zero_crossings,
            checksum: stub.checksum,
            samples: stub.samples,
            transcript: stub.transcript.to_string(),
            audio_bytes: stub.audio_bytes,
            cpu_passes: 4,
            model_delay_ms: 75,
            flush_lateness_ms: 0.0,
            inflight_model_jobs: 1,
        };
        let mut value = serde_json::to_value(partial).expect("serialize partial");
        value["type"] = "partial".into();
        Message::Text(value.to_string().into())
    }

    fn error_text(oldest: u64, newest: u64) -> Message {
        Message::Text(
            serde_json::json!({
                "type": "error", "stage": "inference_request", "kind": "timeout",
                "message": "timed out", "oldest_frame_seq": oldest,
                "newest_frame_seq": newest, "frames": newest - oldest + 1,
                "audio_bytes": (newest - oldest + 1) * 640, "oldest_age_ms": 0.0,
                "newest_age_ms": 0.0, "flush_lateness_ms": 0.0,
                "inference_elapsed_ms": null, "inflight_gateway_batches": 1,
                "gateway_buffer_frames": 0, "inference_status": null, "retryable": true
            })
            .to_string()
            .into(),
        )
    }

    /// Drives `process_inbound` for one session with a measured window
    /// around "now" and a real verifier thread.
    struct Harness {
        session_id: usize,
        now: Instant,
        sent_times: Vec<Instant>,
        tx: mpsc::Sender<Sample>,
        rx: mpsc::Receiver<Sample>,
        inference_errors: Arc<AtomicU64>,
        inference_details: Arc<Mutex<InferenceErrorDetails>>,
        correctness: Arc<Correctness>,
        verify_tx: SyncSender<VerifyJob>,
        verifier: Option<Verifier>,
        check: SessionCheck,
    }

    impl Harness {
        fn new(session_id: usize, verify_every: u64, sent: usize, sample_capacity: usize) -> Self {
            let now = Instant::now();
            let (tx, rx) = mpsc::channel(sample_capacity);
            let correctness = Arc::new(Correctness::new(ExpectedConfig::default(), verify_every));
            let verifier = Verifier::spawn(Arc::clone(&correctness), VERIFY_QUEUE_CAPACITY)
                .expect("spawn verifier");
            Self {
                session_id,
                now,
                sent_times: vec![now; sent],
                tx,
                rx,
                inference_errors: Arc::new(AtomicU64::new(0)),
                inference_details: Arc::new(Mutex::new(InferenceErrorDetails::default())),
                verify_tx: verifier.sender(),
                verifier: Some(verifier),
                correctness,
                check: SessionCheck::default(),
            }
        }

        async fn feed(&mut self, message: Message) -> anyhow::Result<InboundState> {
            process_inbound(
                self.session_id,
                Some(Ok(message)),
                self.now - Duration::from_secs(1),
                self.now + Duration::from_secs(600),
                &self.sent_times,
                &self.tx,
                &self.inference_errors,
                &self.inference_details,
                &self.correctness,
                &self.verify_tx,
                &mut self.check,
            )
            .await
        }

        /// Close the sample channel and drain the verifier, returning the
        /// number of latency samples recorded.
        async fn finish(&mut self) -> usize {
            // Replace our sender with a dead one so the verifier can exit.
            let (dead, _) = sync_channel(0);
            drop(std::mem::replace(&mut self.verify_tx, dead));
            self.verifier
                .take()
                .expect("finish once")
                .finish()
                .expect("verifier");
            let (closed, _) = mpsc::channel(1);
            drop(std::mem::replace(&mut self.tx, closed));
            let mut samples = 0;
            while self.rx.recv().await.is_some() {
                samples += 1;
            }
            samples
        }
    }

    #[tokio::test]
    async fn process_inbound_counts_correctness_errors_without_aborting() {
        let session_id = 5;
        let mut h = Harness::new(session_id, 1, 200, 64);
        let messages = [
            partial_text(session_id, 1, 50),    // ok
            error_text(51, 60),                 // ok: error frames consume range
            partial_text(session_id, 62, 100),  // gap: frame 61 lost
            partial_text(6, 101, 150),          // another session's result
            partial_text(session_id, 151, 250), // frames 201..=250 never sent
        ];
        for message in messages {
            let state = h
                .feed(message)
                .await
                .expect("correctness failures must not abort the session");
            assert_eq!(state, InboundState::Open);
        }
        let samples = h.finish().await;

        assert_eq!(
            samples, 3,
            "partials with known send times still feed latency"
        );
        let correctness = &h.correctness;
        assert_eq!(h.inference_errors.load(Ordering::Relaxed), 1);
        assert_eq!(correctness.errors.load(Ordering::Relaxed), 3);
        assert_eq!(correctness.verified.load(Ordering::Relaxed), 3);
        assert_eq!(correctness.verify_dropped.load(Ordering::Relaxed), 0);
        let (counts, details) = correctness.snapshot();
        let kinds: Vec<_> = counts.iter().map(|count| count.kind).collect();
        for kind in ["continuity_gap", "checksum", "unsent_frame"] {
            assert!(kinds.contains(&kind), "missing {kind} in {kinds:?}");
        }
        assert_eq!(details.len(), 3);
        let gap = details
            .iter()
            .find(|d| d.kind == "continuity_gap")
            .expect("gap sample");
        assert_eq!(gap.oldest_frame_seq, 62);
    }

    #[tokio::test]
    async fn verify_every_samples_value_checks_but_not_continuity() {
        let mut h = Harness::new(1, 3, 500, 64);
        // Six tiling partials (verified: #0 and #3), then one with a gap.
        let mut messages: Vec<_> = (0..6)
            .map(|i| partial_text(1, i * 50 + 1, (i + 1) * 50))
            .collect();
        messages.push(partial_text(1, 302, 350));
        for message in messages {
            h.feed(message).await.expect("process");
        }
        h.finish().await;
        assert_eq!(h.correctness.verified.load(Ordering::Relaxed), 3);
        assert_eq!(h.correctness.errors.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn full_verifier_queue_drops_and_still_records_continuity() {
        let mut h = Harness::new(1, 1, 200, 64);
        // Rendezvous channel with no receiver waiting: every try_send is Full.
        let (full_tx, _rx_kept_alive) = sync_channel(0);
        h.verify_tx = full_tx;
        h.feed(partial_text(1, 1, 50)).await.expect("process");
        h.feed(partial_text(1, 52, 100)).await.expect("process"); // gap
        h.feed(partial_text(2, 101, 150)).await.expect("process"); // wrong session
        h.finish().await;
        let correctness = &h.correctness;
        assert_eq!(correctness.verify_dropped.load(Ordering::Relaxed), 3);
        assert_eq!(correctness.verified.load(Ordering::Relaxed), 0);
        // The gap is still caught inline; the wrong-session values are not.
        assert_eq!(correctness.errors.load(Ordering::Relaxed), 1);
        let (counts, _) = correctness.snapshot();
        assert_eq!(counts.len(), 1);
        assert_eq!(counts[0].kind, "continuity_gap");
    }

    #[tokio::test]
    async fn partial_failing_validate_still_consumes_its_range() {
        let mut h = Harness::new(1, 1, 200, 64);
        h.feed(partial_text(1, 1, 50)).await.expect("process");
        let Message::Text(text) = partial_text(1, 51, 100) else {
            unreachable!()
        };
        let mut bad: serde_json::Value = serde_json::from_str(&text).unwrap();
        bad["transcript"] = "".into();
        let err = h
            .feed(Message::Text(bad.to_string().into()))
            .await
            .expect_err("empty transcript fails validate");
        assert!(format!("{err:#}").contains("validate partial"));
        // Next partial tiles after the invalid one: no double-counted gap.
        h.feed(partial_text(1, 101, 150)).await.expect("process");
        h.finish().await;
        assert_eq!(h.correctness.errors.load(Ordering::Relaxed), 0);
        assert_eq!(h.check.continuity.last_newest(), 150);
    }

    #[tokio::test]
    async fn dropped_tail_partials_are_flagged_at_session_end() {
        // 500 frames sent; partials tile 1..=150, then the gateway goes
        // silent. 350 unreported frames > 300-frame tolerance.
        let mut h = Harness::new(3, 1, 500, 64);
        for i in 0..3 {
            h.feed(partial_text(3, i * 50 + 1, (i + 1) * 50))
                .await
                .expect("process");
        }
        let measure_start = h.now - Duration::from_secs(1);
        check_session_tail(3, &h.sent_times, measure_start, &h.check, &h.correctness);
        h.finish().await;
        assert_eq!(h.correctness.errors.load(Ordering::Relaxed), 1);
        let (counts, details) = h.correctness.snapshot();
        assert_eq!(counts.len(), 1);
        assert_eq!(counts[0].kind, "missing_tail");
        assert_eq!(details[0].message_type, "session_end");
        assert_eq!(
            (details[0].oldest_frame_seq, details[0].newest_frame_seq),
            (151, 500)
        );
    }

    #[tokio::test]
    async fn normal_close_tail_and_unmeasured_sessions_pass() {
        // Last ~2 flushes unreported at close: legitimate.
        let mut h = Harness::new(3, 1, 500, 64);
        for i in 0..8 {
            h.feed(partial_text(3, i * 50 + 1, (i + 1) * 50))
                .await
                .expect("process");
        }
        let measure_start = h.now - Duration::from_secs(1);
        check_session_tail(3, &h.sent_times, measure_start, &h.check, &h.correctness);
        // A session that sent nothing in the measured window is not checked,
        // nor is one that sent nothing at all.
        let silent = SessionCheck::default();
        let after = h.now + Duration::from_secs(1);
        check_session_tail(4, &h.sent_times, after, &silent, &h.correctness);
        check_session_tail(5, &[], measure_start, &silent, &h.correctness);
        h.finish().await;
        assert_eq!(h.correctness.errors.load(Ordering::Relaxed), 0);
    }

    /// Receive-path cost per measured partial with value verification handed
    /// to the verifier thread, vs. verification off (the decode+latency
    /// floor). Run: `cargo test --release -p stt-loadgen --bin stt-loadgen
    /// receive_path_cost -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore = "microbenchmark; run explicitly in --release"]
    async fn receive_path_cost() {
        let n = 2_000_u64;
        let messages: Vec<_> = (0..n)
            .map(|i| partial_text(9, i * 50 + 1, (i + 1) * 50))
            .collect();
        for verify_every in [0, 1] {
            let mut h = Harness::new(9, verify_every, (n * 50) as usize, n as usize + 1);
            let started = std::time::Instant::now();
            for message in messages.iter().cloned() {
                h.feed(message).await.expect("process");
            }
            let per = started.elapsed() / n as u32;
            h.finish().await;
            assert_eq!(h.correctness.errors.load(Ordering::Relaxed), 0);
            println!(
                "verify_every={verify_every}: {per:?}/partial on the receive path \
                 (verified {}, dropped {})",
                h.correctness.verified.load(Ordering::Relaxed),
                h.correctness.verify_dropped.load(Ordering::Relaxed)
            );
        }
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
