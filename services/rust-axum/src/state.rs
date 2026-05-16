use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use axum::http::HeaderValue;

#[derive(Clone)]
pub(crate) struct AppContext {
    pub(crate) clients: Arc<[reqwest::Client]>,
    pub(crate) next_client: Arc<AtomicUsize>,
    pub(crate) inference_url: Arc<str>,
    pub(crate) cpu_passes_header: HeaderValue,
    pub(crate) cpu_passes: u32,
    pub(crate) model_delay: Duration,
    pub(crate) flush_interval: Duration,
    pub(crate) flush_phase_jitter: Duration,
}

impl AppContext {
    pub(crate) fn inference_client(&self) -> &reqwest::Client {
        let index = self.next_client.fetch_add(1, Ordering::Relaxed) % self.clients.len();
        &self.clients[index]
    }
}
