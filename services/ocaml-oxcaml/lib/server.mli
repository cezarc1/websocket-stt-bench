(** HTTP server that upgrades [/ws/stt] connections to WebSocket and delegates
    per-connection lifecycle to {!Session}. Anything else returns 404. *)

val start : Config.t -> unit Async.Deferred.t
