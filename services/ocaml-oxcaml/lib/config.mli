(** Gateway runtime configuration sourced from the process env.

    Matches the per-gateway env-var contract documented in [docker-compose.yml] (see the
    [x-*-env] anchors): PORT, INFERENCE_URL, INFERENCE_HTTP_CLIENTS, WORKER_THREADS,
    FLUSH_INTERVAL_MS, FLUSH_PHASE_JITTER_MS, CPU_PASSES, MODEL_DELAY_MS.

    NOTE: [inference_http_clients] and [worker_threads] are accepted for parity with the
    cross-runtime env contract but are currently no-ops: the inference path opens a fresh
    TCP connection per flush, and Async is single-domain. Both will start affecting
    behaviour when keep-alive pooling and [janestreet/parallel] respectively land. *)

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
