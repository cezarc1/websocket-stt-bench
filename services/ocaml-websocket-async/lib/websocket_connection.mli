open! Core
open! Async

(** Run one upgraded WebSocket connection.

    [ws_in] contains frames received from the client. [ws_out] is consumed by
    [websocket-async] and written to the socket. The first client frame must be a
    canonical start message; subsequent binary frames must be exactly
    [Protocol.frame_bytes]. *)

val run
  :  config:Config.t
  -> inference:Inference.t
  -> ws_in:Websocket_async.Frame.t Pipe.Reader.t
  -> ws_out:Websocket_async.Frame.t Pipe.Writer.t
  -> unit Deferred.t
