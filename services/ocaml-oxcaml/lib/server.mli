(** HTTP listener + router. Reads the request line ({!Http1}), serves [/health], performs
    the [/ws/stt] upgrade ({!Websocket_handshake}) and hands the socket to
    {!Websocket_connection}; anything else is 404. Connection/protocol logic lives in
    those modules, not here. *)

val start : Config.t -> unit Async.Deferred.t
