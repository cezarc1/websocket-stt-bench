#pragma once

#include "config.hpp"
#include "inference.hpp"

namespace stt {

// Spawn `config.worker_threads` uWS::App instances, each on its own thread,
// each listening on `config.port` via SO_REUSEPORT. Blocks the calling thread
// until every worker thread exits (i.e. until Ctrl-C). The inference client
// is shared across all workers — its internal libcurl thread pool already
// caps concurrency at `config.inference_http_clients`.
void run_server(const Config& config, InferenceClient& inference);

}  // namespace stt
