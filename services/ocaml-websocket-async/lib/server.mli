open! Core
open! Async

(** Start the stock OCaml Async/cohttp/websocket-async gateway. *)

val start : Config.t -> unit Deferred.t
