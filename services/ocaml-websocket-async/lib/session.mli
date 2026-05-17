(** Per-WebSocket-connection session state.

    Three concurrent activities run for each open socket:
    - {b receive loop}: reads framed PCM off the wire; enqueues each frame into a
      per-connection buffer.
    - {b flush loop}: ticks every [Config.flush_interval_ms]; drains the buffer; calls
      [Inference.send]; then emits a [Partial] JSON on an outbound pipe.
    - {b writer loop}: forwards JSON strings from the outbound pipe to the WebSocket as
      text frames.

    The load-bearing invariant is structural: the flush loop does not fork inference
    work, so one session can have at most one in-flight inference request.

    Frames violating the 640-byte size invariant cause a close 1003. Text frames sent
    after the [Start] handshake cause a close 1002. *)

open! Core
open! Async

type close_action =
  | Continue
  | Close of
      { code : int
      ; reason : string
      }

type t

val create
  :  config:Config.t
  -> inference:Inference.t
  -> outbound:string Pipe.Writer.t
  -> t

(** Validate a freshly-received binary frame (the raw [Websocket_frame] string) and
    enqueue it. *)
val on_binary : t -> string -> close_action

(** Start the periodic flush loop. Returns when the outbound pipe closes. *)
val run_flush_loop : t -> unit Deferred.t
