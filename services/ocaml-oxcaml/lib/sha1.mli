(** Pure-OCaml SHA-1. The only consumer is the WebSocket Sec-WebSocket-Accept handshake —
    run once per upgrade, never on the per-frame hot path. *)

val digest_string : string -> string
