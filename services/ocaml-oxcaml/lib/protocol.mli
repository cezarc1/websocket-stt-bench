(** Wire-protocol marshalling.

    Matches the shared protocol contract in [CLAUDE.md] and
    [loadgen/rust/src/protocol.rs]. Boundary validation is strict:
    - [Start_message.of_yojson] rejects unknown fields and wrong [type] tags.
    - [Infer_response.of_yojson] rejects unknown fields from the inference server (the
      gateway never produces fields the client schema didn't expect).
    - [Partial.to_yojson] emits exactly the 14 fields the conformance
      [partial_schema_and_golden] case enforces. *)

module Start_message : sig
  type t = { type_ : string }

  val of_yojson : Yojson.Safe.t -> (t, string) Result.t
end

module Infer_response : sig
  type t =
    { rms : float
    ; zero_crossings : int
    ; checksum : int
    ; samples : int
    ; transcript : string
    ; audio_bytes : int
    }

  val of_yojson : Yojson.Safe.t -> (t, string) Result.t
end

module Partial : sig
  type t =
    { type_ : string
    ; oldest_frame_seq : int
    ; newest_frame_seq : int
    ; frames : int
    ; rms : float
    ; zero_crossings : int
    ; checksum : int
    ; samples : int
    ; transcript : string
    ; audio_bytes : int
    ; cpu_passes : int
    ; model_delay_ms : int
    ; flush_lateness_ms : float
    ; inflight_model_jobs : int
    }

  val to_yojson : t -> Yojson.Safe.t
  val to_string : t -> string
end

(** Mid-session error envelope. Field set matches
    [loadgen/rust/src/protocol.rs::ErrorMessage] exactly; loadgen decodes with
    [deny_unknown_fields] so missing/extra fields fail parse. *)
module Error : sig
  type t =
    { type_ : string
    ; stage : string
    ; kind : string
    ; message : string
    ; oldest_frame_seq : int
    ; newest_frame_seq : int
    ; frames : int
    ; audio_bytes : int
    ; oldest_age_ms : float
    ; newest_age_ms : float
    ; flush_lateness_ms : float
    ; inference_elapsed_ms : float option
    ; inflight_gateway_batches : int
    ; gateway_buffer_frames : int
    ; inference_status : int option
    ; retryable : bool
    }

  val to_yojson : t -> Yojson.Safe.t
  val to_string : t -> string
end

(** Frame size assertion: every binary frame on the wire must be exactly 640 bytes (16 kHz
    × 20 ms × 2 bytes = 640). *)
val frame_bytes : int
