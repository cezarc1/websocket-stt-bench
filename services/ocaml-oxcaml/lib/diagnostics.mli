open! Core
open! Async

(** Low-overhead process diagnostics and sampled traces for OxCaml benchmark experiments.

    Diagnostics are opt-in via [OXCAML_DIAG=1]. When disabled, record functions are cheap
    no-ops and no stderr output is emitted. Sampled Chrome trace output is separately
    opt-in via [OXCAML_TRACE=1]. *)

module Config : sig
  type t =
    { enabled : bool
    ; interval_ms : int
    ; sample_every : int
    ; trace_enabled : bool
    ; trace_file : string option
    ; trace_sample_every : int
    ; trace_flush_interval_ms : int
    ; trace_frame_sample_every : int
    ; trace_max_events : int
    }

  val disabled : t
  val of_getenv : (string -> string option) -> t
  val from_env : unit -> t
end

type t

type timing_metric =
  | Inference
  | Flush_cycle
  | Drain
  | Inference_write
  | Inference_read_head
  | Inference_read_body
  | Serialization
  | Outbound_write
  | Response_parse

type timing_sample

type trace_arg =
  | Int_arg of string * int
  | Float_arg of string * float
  | String_arg of string * string
  | Bool_arg of string * bool

val disabled : t
val create : Config.t -> t
val enabled : t -> bool
val tracing_enabled : t -> bool
val run_periodic : t -> unit Deferred.t
val run_trace_periodic : t -> unit Deferred.t
val write_trace_now : t -> unit
val snapshot_json_for_test : t -> string
val trace_json_for_test : t -> string option
val record_session_opened : t -> int
val record_session_closed : t -> session_id:int -> unit
val record_binary_frame : t -> session_id:int -> seq:int -> bytes:int -> unit
val record_flush_tick : t -> unit
val record_flush_skip_inflight : t -> unit
val record_flush_skip_empty : t -> unit
val record_batch : t -> frames:int -> bytes:int -> unit

val record_trace_instant
  :  t
  -> name:string
  -> trace_tid:int
  -> trace_args:trace_arg list
  -> unit

val record_trace_counter
  :  t
  -> name:string
  -> trace_tid:int
  -> trace_args:trace_arg list
  -> unit

val start_timing : t -> timing_metric -> timing_sample

val finish_timing
  :  t
  -> timing_metric
  -> ?trace_tid:int
  -> ?trace_args:trace_arg list
  -> timing_sample
  -> unit
