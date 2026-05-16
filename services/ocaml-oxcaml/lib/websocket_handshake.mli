open! Core
open! Async

(** RFC 6455 opening handshake. SHA-1 and Base64 are implementation details hidden behind
    this module — the only public surface is upgrade validation and the 101 response. *)

(** [accept_key ~key] is the RFC 6455 §1.3 Sec-WebSocket-Accept value: base64(sha1(key ^
    GUID)). Exposed for the conformance/accept-vector test. *)
val accept_key : key:string -> string

(** [Some sec_websocket_key] if [req] is a well-formed WebSocket upgrade (GET, the
    Upgrade/Connection headers, Sec-WebSocket-Version: 13, a Sec-WebSocket-Key); [None]
    otherwise so the caller can reply 400. *)
val upgrade_key : Http1.request -> string option

(** Write the [101 Switching Protocols] response with the computed Sec-WebSocket-Accept
    for [ws_key]. *)
val write_upgrade_response : Writer.t -> ws_key:string -> unit Async.Deferred.t
