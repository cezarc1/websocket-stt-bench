use std::{sync::Arc, time::Duration};

use anyhow::{Context, bail};
use clap::Parser;
use reqwest::header::CONTENT_TYPE;
use serde::Serialize;
use stt_loadgen::inferbench::{
    BenchError, BenchErrorCounts, BenchErrorKind, BenchSummary, DEFAULT_INFERENCE_FRAMES,
    Percentiles, inference_payload,
};
use tokio::{
    sync::{Semaphore, mpsc},
    task::JoinSet,
    time::{Instant, sleep_until},
};
use tracing_subscriber::{EnvFilter, fmt};

const DEFAULT_TIMEOUT_MS: u64 = 2_000;
const DEFAULT_CONNECT_TIMEOUT_MS: u64 = 1_000;
const DEFAULT_DURATION_SECS: u64 = 30;
const DEFAULT_CONCURRENCY: usize = 64;
const DEFAULT_CLIENTS: usize = 4;
const DEFAULT_CPU_PASSES: u32 = 4;

#[derive(Debug, Parser)]
struct Args {
    /// Full /infer URL, for example http://192.0.2.10:30900/infer.
    #[arg(long)]
    url: String,
    /// Max in-flight requests. In closed-loop mode this is also worker count.
    #[arg(long, default_value_t = DEFAULT_CONCURRENCY)]
    concurrency: usize,
    /// Number of reqwest HTTP/2 clients to spread requests over.
    #[arg(long, default_value_t = DEFAULT_CLIENTS)]
    clients: usize,
    /// Optional open-loop request rate. If omitted, runs closed-loop.
    #[arg(long)]
    rps: Option<f64>,
    #[arg(long, default_value_t = DEFAULT_DURATION_SECS)]
    duration_secs: u64,
    #[arg(long, default_value_t = DEFAULT_INFERENCE_FRAMES)]
    payload_frames: usize,
    #[arg(long, default_value_t = DEFAULT_CPU_PASSES)]
    cpu_passes: u32,
    #[arg(long, default_value_t = DEFAULT_TIMEOUT_MS)]
    timeout_ms: u64,
    #[arg(long, default_value_t = DEFAULT_CONNECT_TIMEOUT_MS)]
    connect_timeout_ms: u64,
}

#[derive(Debug, Serialize)]
struct Output {
    url: String,
    mode: &'static str,
    duration_secs: u64,
    concurrency: usize,
    clients: usize,
    target_rps: Option<f64>,
    payload_frames: usize,
    payload_bytes: usize,
    cpu_passes: u32,
    timeout_ms: u64,
    connect_timeout_ms: u64,
    attempted: u64,
    completed: u64,
    errors: BenchErrorCounts,
    error_samples: Vec<String>,
    attempted_rps: f64,
    completed_rps: f64,
    latency: Percentiles,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("warn".parse().unwrap()))
        .init();

    let args = Args::parse();
    validate_args(&args)?;

    let payload = Arc::new(inference_payload(args.payload_frames));
    let clients = Arc::new(build_clients(&args)?);
    let (tx, rx) = mpsc::unbounded_channel::<Result<u64, BenchError>>();
    let duration = Duration::from_secs(args.duration_secs);
    let started = Instant::now();

    match args.rps {
        Some(rps) => {
            run_open_loop(
                &args,
                rps,
                duration,
                Arc::clone(&clients),
                Arc::clone(&payload),
                tx,
            )
            .await?;
        }
        None => {
            run_closed_loop(
                &args,
                duration,
                Arc::clone(&clients),
                Arc::clone(&payload),
                tx,
            )
            .await?;
        }
    }

    let elapsed = started.elapsed().as_secs_f64();
    let summary = collect_results(rx).await;
    let attempted = summary.attempted();
    let completed = summary.completed;
    let latency = summary.latency_percentiles();
    let output = Output {
        url: args.url,
        mode: if args.rps.is_some() {
            "open_loop"
        } else {
            "closed_loop"
        },
        duration_secs: args.duration_secs,
        concurrency: args.concurrency,
        clients: args.clients,
        target_rps: args.rps,
        payload_frames: args.payload_frames,
        payload_bytes: payload.len(),
        cpu_passes: args.cpu_passes,
        timeout_ms: args.timeout_ms,
        connect_timeout_ms: args.connect_timeout_ms,
        attempted,
        completed,
        errors: summary.errors,
        error_samples: summary.error_samples,
        attempted_rps: attempted as f64 / elapsed,
        completed_rps: completed as f64 / elapsed,
        latency,
    };

    println!("{}", serde_json::to_string_pretty(&output)?);
    Ok(())
}

fn validate_args(args: &Args) -> anyhow::Result<()> {
    if args.concurrency == 0 {
        bail!("--concurrency must be > 0");
    }
    if args.clients == 0 {
        bail!("--clients must be > 0");
    }
    if args.duration_secs == 0 {
        bail!("--duration-secs must be > 0");
    }
    if args.payload_frames == 0 {
        bail!("--payload-frames must be > 0");
    }
    if let Some(rps) = args.rps
        && (!rps.is_finite() || rps <= 0.0)
    {
        bail!("--rps must be a finite positive number");
    }
    Ok(())
}

fn build_clients(args: &Args) -> anyhow::Result<Vec<reqwest::Client>> {
    (0..args.clients)
        .map(|_| {
            reqwest::Client::builder()
                .http2_prior_knowledge()
                .pool_idle_timeout(Duration::from_secs(60))
                .http2_keep_alive_interval(Duration::from_secs(15))
                .http2_keep_alive_while_idle(true)
                .connect_timeout(Duration::from_millis(args.connect_timeout_ms))
                .timeout(Duration::from_millis(args.timeout_ms))
                .build()
                .context("build reqwest client")
        })
        .collect()
}

async fn run_closed_loop(
    args: &Args,
    duration: Duration,
    clients: Arc<Vec<reqwest::Client>>,
    payload: Arc<Vec<u8>>,
    tx: mpsc::UnboundedSender<Result<u64, BenchError>>,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + duration;
    let mut tasks = JoinSet::new();
    for worker_id in 0..args.concurrency {
        let client = clients[worker_id % clients.len()].clone();
        let url = args.url.clone();
        let payload = Arc::clone(&payload);
        let tx = tx.clone();
        let cpu_passes = args.cpu_passes;
        tasks.spawn(async move {
            while Instant::now() < deadline {
                let result = send_infer(&client, &url, &payload, cpu_passes).await;
                let _ = tx.send(result);
            }
        });
    }
    drop(tx);
    while let Some(result) = tasks.join_next().await {
        result.context("closed-loop worker panicked")?;
    }
    Ok(())
}

async fn run_open_loop(
    args: &Args,
    rps: f64,
    duration: Duration,
    clients: Arc<Vec<reqwest::Client>>,
    payload: Arc<Vec<u8>>,
    tx: mpsc::UnboundedSender<Result<u64, BenchError>>,
) -> anyhow::Result<()> {
    let requests = (rps * duration.as_secs_f64()).floor() as u64;
    let interval = Duration::from_secs_f64(1.0 / rps);
    let semaphore = Arc::new(Semaphore::new(args.concurrency));
    let start = Instant::now();
    let mut tasks = JoinSet::new();

    for request_id in 0..requests {
        sleep_until(start + interval.mul_f64(request_id as f64)).await;
        let permit = Arc::clone(&semaphore)
            .acquire_owned()
            .await
            .context("acquire request concurrency permit")?;
        let client = clients[request_id as usize % clients.len()].clone();
        let url = args.url.clone();
        let payload = Arc::clone(&payload);
        let tx = tx.clone();
        let cpu_passes = args.cpu_passes;
        tasks.spawn(async move {
            let result = send_infer(&client, &url, &payload, cpu_passes).await;
            drop(permit);
            let _ = tx.send(result);
        });
    }
    drop(tx);
    while let Some(result) = tasks.join_next().await {
        result.context("open-loop request task panicked")?;
    }
    Ok(())
}

async fn send_infer(
    client: &reqwest::Client,
    url: &str,
    payload: &[u8],
    cpu_passes: u32,
) -> Result<u64, BenchError> {
    let started = Instant::now();
    let response = client
        .post(url)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header("x-cpu-passes", cpu_passes.to_string())
        .body(payload.to_vec())
        .send()
        .await
        .map_err(classify_reqwest_error)?;

    if !response.status().is_success() {
        return Err(BenchError::new(
            BenchErrorKind::HttpStatus,
            format!("HTTP {}", response.status()),
        ));
    }
    response
        .bytes()
        .await
        .map_err(classify_reqwest_error)
        .map(|_| started.elapsed().as_micros().min(u128::from(u64::MAX)) as u64)
}

fn classify_reqwest_error(error: reqwest::Error) -> BenchError {
    let message = format!("{error:?}");
    if error.is_timeout() {
        BenchError::new(BenchErrorKind::Timeout, message)
    } else if error.is_connect() {
        BenchError::new(BenchErrorKind::Connect, message)
    } else {
        BenchError::new(BenchErrorKind::Request, message)
    }
}

async fn collect_results(mut rx: mpsc::UnboundedReceiver<Result<u64, BenchError>>) -> BenchSummary {
    let mut summary = BenchSummary::default();
    while let Some(result) = rx.recv().await {
        summary.record(result);
    }
    summary
}
