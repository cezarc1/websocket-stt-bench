(** Gateway runtime configuration sourced from the process env.

    Matches the per-gateway env-var contract documented in [docker-compose.yml] (see the
    [x-*-env] anchors): PORT, INFERENCE_URL, INFERENCE_HTTP_CLIENTS, WORKER_THREADS,
    FLUSH_INTERVAL_MS, FLUSH_PHASE_JITTER_MS, CPU_PASSES, MODEL_DELAY_MS.

    NOTE: [inference_http_clients] and [worker_threads] are accepted for parity with the
    cross-runtime env contract but are currently no-ops. The inference path already uses a
    persistent per-session keep-alive connection; the one-inflight-per-connection
    invariant makes requests on it strictly sequential, so a multi-connection pool would
    add nothing — hence [inference_http_clients] stays a no-op. [worker_threads] is a
    no-op in this stock-OCaml Async comparison because the gateway stays single-domain. *)

type t =
  { port : int
  ; inference_host : string
  ; inference_port : int
  ; inference_http_clients : int
  ; worker_threads : int
  ; flush_interval_ms : int
  ; flush_phase_jitter_ms : int
  ; cpu_passes : int
  ; model_delay_ms : int
  }

val from_env : unit -> t
val to_string_hum : t -> string
