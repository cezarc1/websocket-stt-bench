open! Core
open! Async

(** Minimal HTTP/1.1 line helpers shared by the WebSocket-upgrade server path and the
    inference keep-alive client. Not a general HTTP parser — it only consumes what those
    two narrow paths need. *)

(** Read header lines until a blank line ([`Ok]) or EOF before one ([`Eof], i.e. the peer
    closed mid-headers). Keys are lowercased and values stripped; colon-less lines are
    skipped. *)
val read_headers : Reader.t -> [ `Ok of (string * string) list | `Eof ] Async.Deferred.t

(** Case-insensitive lookup against the assoc returned by {!read_headers}. *)
val find : (string * string) list -> string -> string option

type request =
  { meth : string
  ; path : string
  ; version : string
  ; headers : (string * string) list
  }

(** Read the request line + headers. [None] if the connection closes before a request line
    or the line is unparseable. A peer that closes mid-headers yields a request with empty
    headers; callers reject it downstream, e.g. failed WebSocket upgrade -> 400. *)
val read_request : Reader.t -> request option Async.Deferred.t
