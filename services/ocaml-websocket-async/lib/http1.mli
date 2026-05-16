open! Core
open! Async

(** Minimal HTTP/1.1 line helpers for the inference keep-alive client. Not a general HTTP
    parser — it only consumes the response headers this gateway needs. *)

(** Read header lines until a blank line ([`Ok]) or EOF before one ([`Eof], i.e. the peer
    closed mid-headers). Keys are lowercased and values stripped; colon-less lines are
    skipped. *)
val read_headers : Reader.t -> [ `Ok of (string * string) list | `Eof ] Async.Deferred.t

(** Case-insensitive lookup against the assoc returned by {!read_headers}. *)
val find : (string * string) list -> string -> string option
