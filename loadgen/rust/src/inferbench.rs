use hdrhistogram::Histogram;
use serde::Serialize;

use crate::protocol::{FRAME_BYTES, frame_payload};

pub const DEFAULT_INFERENCE_FRAMES: usize = 50;

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BenchErrorKind {
    Connect,
    Timeout,
    HttpStatus,
    Request,
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct BenchErrorCounts {
    pub connect: u64,
    pub timeout: u64,
    pub http_status: u64,
    pub request: u64,
}

impl BenchErrorCounts {
    pub fn total(&self) -> u64 {
        self.connect + self.timeout + self.http_status + self.request
    }
}

#[derive(Debug)]
pub struct BenchSummary {
    pub completed: u64,
    pub errors: BenchErrorCounts,
    pub error_samples: Vec<String>,
    latency_us: Histogram<u64>,
}

impl Default for BenchSummary {
    fn default() -> Self {
        Self {
            completed: 0,
            errors: BenchErrorCounts::default(),
            latency_us: Histogram::new_with_max(60_000_000, 3).expect("valid histogram bounds"),
            error_samples: Vec::new(),
        }
    }
}

impl BenchSummary {
    pub fn record(&mut self, result: Result<u64, BenchError>) {
        match result {
            Ok(latency_us) => {
                self.completed += 1;
                self.latency_us
                    .record(latency_us)
                    .expect("latency should fit histogram");
            }
            Err(error) => {
                match error.kind {
                    BenchErrorKind::Connect => self.errors.connect += 1,
                    BenchErrorKind::Timeout => self.errors.timeout += 1,
                    BenchErrorKind::HttpStatus => self.errors.http_status += 1,
                    BenchErrorKind::Request => self.errors.request += 1,
                }
                if self.error_samples.len() < 5 {
                    self.error_samples.push(error.message);
                }
            }
        }
    }

    pub fn attempted(&self) -> u64 {
        self.completed + self.errors.total()
    }

    pub fn latency_percentiles(&self) -> Percentiles {
        Percentiles::from_histogram(&self.latency_us)
    }
}

#[derive(Debug, Clone)]
pub struct BenchError {
    pub kind: BenchErrorKind,
    pub message: String,
}

impl BenchError {
    pub fn new(kind: BenchErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Percentiles {
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub max_ms: f64,
}

impl Percentiles {
    fn from_histogram(histogram: &Histogram<u64>) -> Self {
        if histogram.is_empty() {
            return Self {
                p50_ms: 0.0,
                p95_ms: 0.0,
                p99_ms: 0.0,
                p999_ms: 0.0,
                max_ms: 0.0,
            };
        }
        Self {
            p50_ms: us_to_ms(histogram.value_at_quantile(0.50)),
            p95_ms: us_to_ms(histogram.value_at_quantile(0.95)),
            p99_ms: us_to_ms(histogram.value_at_quantile(0.99)),
            p999_ms: us_to_ms(histogram.value_at_quantile(0.999)),
            max_ms: us_to_ms(histogram.max()),
        }
    }
}

pub fn inference_payload(frames: usize) -> Vec<u8> {
    let mut payload = Vec::with_capacity(frames * FRAME_BYTES);
    for seq in 1..=frames as u64 {
        payload.extend_from_slice(&frame_payload(0, seq));
    }
    payload
}

fn us_to_ms(value: u64) -> f64 {
    value as f64 / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::FRAME_BYTES;

    #[test]
    fn inference_payload_uses_requested_frame_count() {
        let payload = inference_payload(50);

        assert_eq!(payload.len(), 50 * FRAME_BYTES);
    }

    #[test]
    fn summary_counts_successes_and_error_kinds() {
        let mut summary = BenchSummary::default();
        summary.record(Ok(1_000));
        summary.record(Ok(2_000));
        summary.record(Err(BenchError::new(BenchErrorKind::Timeout, "timed out")));
        summary.record(Err(BenchError::new(BenchErrorKind::HttpStatus, "http 503")));
        summary.record(Err(BenchError::new(
            BenchErrorKind::Request,
            "request reset",
        )));

        assert_eq!(summary.attempted(), 5);
        assert_eq!(summary.completed, 2);
        assert_eq!(summary.errors.timeout, 1);
        assert_eq!(summary.errors.http_status, 1);
        assert_eq!(summary.errors.request, 1);
        assert_eq!(summary.errors.total(), 3);
    }

    #[test]
    fn summary_keeps_capped_error_samples() {
        let mut summary = BenchSummary::default();

        for index in 0..10 {
            summary.record(Err(BenchError::new(
                BenchErrorKind::Request,
                format!("error {index}"),
            )));
        }

        assert_eq!(summary.error_samples.len(), 5);
        assert_eq!(summary.error_samples[0], "error 0");
        assert_eq!(summary.error_samples[4], "error 4");
    }
}
