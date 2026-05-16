(** Per-WebSocket-connection session state.

    Three concurrent activities run for each open socket:
    - {b receive loop}: reads framed PCM off the wire; enqueues each frame into a
      per-connection buffer.
    - {b flush loop}: ticks every [Config.flush_interval_ms]; drains the buffer; takes the
      [Inflight_capability.t] from an [Mvar.t]; calls [Inference.send]; on success puts
      the [Token]-derived capability back; emits a [Partial] JSON on an outbound pipe.
    - {b writer loop}: forwards JSON strings from the outbound pipe to the WebSocket as
      text frames.

    The [Mvar] enforces the load-bearing invariant — at most one in-flight inference per
    connection — at runtime: it is empty while a capability is consumed, so a concurrent
    flush tick finds nothing to take and skips. [Inflight_capability.t] is an opaque
    mint-once type (see its [.mli]) which makes the discipline explicit in the API shape,
    but the enforcement is the [Mvar], not the compiler.

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

(** Validate a freshly-received binary frame and enqueue it. *)
val on_binary : t -> Bigstring.t -> close_action

(** Start the periodic flush loop. Returns when the outbound pipe closes. *)
val run_flush_loop : t -> unit Deferred.t
