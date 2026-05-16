//! Blocking HTTP/1.1 inference client.
//!
//! One `Inference` per connection thread → one `ureq::Agent` → one pooled
//! keep-alive TCP connection to the inference server, reused across
//! flushes. The thread issues the POST inline, so the "at most one
//! in-flight inference per connection" invariant is structural: a second
//! request is unrepresentable until this call returns. No semaphore, no
//! flag. The response buffer is reused too, so a steady-state flush
//! allocates nothing on this path.

use std::io::Read;
use std::time::{Duration, Instant};

use ureq::Agent;

use crate::config::{CPU_PASSES_HEADER, Config, INFERENCE_CONNECT_TIMEOUT, INFERENCE_TIMEOUT};
use crate::protocol::{ErrorKind, ErrorStage, InferResponse};

pub struct InferenceError {
    pub stage: ErrorStage,
    pub kind: ErrorKind,
    pub message: String,
    pub status: Option<u16>,
    pub retryable: bool,
    pub elapsed: Duration,
}

pub struct Inference {
    agent: Agent,
    response: Vec<u8>,
}

impl Inference {
    pub fn new() -> Self {
        let agent: Agent = Agent::config_builder()
            .timeout_connect(Some(INFERENCE_CONNECT_TIMEOUT))
            .timeout_global(Some(INFERENCE_TIMEOUT))
            // Inspect 4xx/5xx ourselves instead of having them raised as
            // transport errors, so the wire `kind` mirrors the other
            // gateways exactly.
            .http_status_as_error(false)
            .https_only(false)
            .build()
            .into();
        Self {
            agent,
            response: Vec::with_capacity(512),
        }
    }

    /// POST the concatenated PCM and parse the inference envelope.
    /// `elapsed` is wall time spent in the call.
    pub fn infer(
        &mut self,
        config: &Config,
        body: &[u8],
    ) -> Result<(InferResponse, Duration), InferenceError> {
        let started = Instant::now();
        let fail = |stage, kind, message, status, retryable| InferenceError {
            stage,
            kind,
            message,
            status,
            retryable,
            elapsed: started.elapsed(),
        };

        let mut response = match self
            .agent
            .post(&config.inference_url)
            .header(CPU_PASSES_HEADER, &config.cpu_passes_header)
            .send(body)
        {
            Ok(response) => response,
            Err(error) => {
                let (kind, retryable) = classify_transport(&error);
                return Err(fail(
                    ErrorStage::InferenceRequest,
                    kind,
                    error.to_string(),
                    None,
                    retryable,
                ));
            }
        };

        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            let (kind, retryable) = classify_status(status);
            return Err(fail(
                ErrorStage::InferenceRequest,
                kind,
                format!("inference returned status {status}"),
                Some(status),
                retryable,
            ));
        }

        self.response.clear();
        if let Err(error) = response
            .body_mut()
            .as_reader()
            .read_to_end(&mut self.response)
        {
            return Err(fail(
                ErrorStage::InferenceResponseParse,
                ErrorKind::ConnectionReset,
                error.to_string(),
                Some(status),
                true,
            ));
        }

        match serde_json::from_slice::<InferResponse>(&self.response) {
            Ok(infer) => Ok((infer, started.elapsed())),
            Err(error) => Err(fail(
                ErrorStage::InferenceResponseParse,
                ErrorKind::ParseError,
                error.to_string(),
                Some(status),
                false,
            )),
        }
    }
}

/// Mirrors rust-axum's `classify_status`: 429 and 5xx are retryable;
/// any other non-2xx is reported as `http_5xx` but not retryable.
fn classify_status(status: u16) -> (ErrorKind, bool) {
    if status == 429 {
        (ErrorKind::Http429, true)
    } else if (500..600).contains(&status) {
        (ErrorKind::Http5xx, true)
    } else {
        (ErrorKind::Http5xx, false)
    }
}

fn classify_transport(error: &ureq::Error) -> (ErrorKind, bool) {
    match error {
        ureq::Error::Timeout(_) => (ErrorKind::Timeout, true),
        _ => (ErrorKind::ConnectionReset, true),
    }
}
