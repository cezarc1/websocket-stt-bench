(** Minimal base64 encoder. Used only for Sec-WebSocket-Accept, so we don't bother with
    the decoder or URL-safe alphabet variants. *)

val encode : string -> string
