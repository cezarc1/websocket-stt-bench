open! Core
open! Async

(** Drives one upgraded WebSocket for the STT protocol. Owns the three concurrent loops
    (receive / outbound writer / flush), ping/pong, and the protocol close codes (1002 for
    a bad start handshake or framing violation, 1003 for a wrong-sized PCM frame via
    {!Session}). Returns when the connection is fully torn down. {!Session} stays a pure
    STT state machine and never sees a WebSocket opcode. *)

val run
  :  config:Config.t
  -> inference:Inference.t
  -> reader:Reader.t
  -> writer:Writer.t
  -> unit Async.Deferred.t
