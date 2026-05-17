(** Run one upgraded WebSocket connection.

    The first client frame must be a canonical start message; subsequent binary frames
    must be exactly [Protocol.frame_bytes]. *)

val run
  :  config:Config.t
  -> inference:Inference.t
  -> reader:Async.Reader.t
  -> writer:Async.Writer.t
  -> unit Async.Deferred.t
