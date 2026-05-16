(** Minimal RFC 6455 server-side WebSocket framing.

    Replaces the [websocket-async] dependency (which transitively pulled in [digestif],
    which doesn't compile on the OxCaml 5.2.0+ox switch invariant). Implements only what
    the STT protocol uses: text payloads for the start handshake and partial messages,
    binary payloads for 640-byte PCM frames, ping/pong, and close.

    {!read} enforces RFC 6455 §5.1: an unmasked client frame yields [`Error] (the server
    layer turns that into a 1002 close). Frames larger than 1 GiB also yield [`Error].
    Fragmentation/continuation handling is intentionally absent — the server treats a
    [Continuation] opcode as a protocol violation since this benchmark never negotiates
    fragmented frames. *)

type opcode =
  | Continuation
  | Text
  | Binary
  | Close
  | Ping
  | Pong
  | Other of int

type t =
  { fin : bool
  ; opcode : opcode
  ; payload : string
  }

(** Read one frame from a transport. Returns [`Eof] when the peer closes the underlying
    TCP connection. *)
val read : Async.Reader.t -> [ `Eof | `Ok of t | `Error of string ] Async.Deferred.t

(** Write one server-side frame (no masking — server frames per RFC 6455 must be
    unmasked). *)
val write : Async.Writer.t -> t -> unit Async.Deferred.t

val text : string -> t
val binary : string -> t
val close : ?code:int -> unit -> t
val pong : string -> t
