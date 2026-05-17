(** Minimal RFC 6455 server-side WebSocket framing for the STT benchmark protocol. *)

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

val read : Async.Reader.t -> [ `Eof | `Ok of t | `Error of string ] Async.Deferred.t
val write : Async.Writer.t -> t -> unit Async.Deferred.t
val text : string -> t
val binary : string -> t
val close : ?code:int -> unit -> t
val pong : string -> t
