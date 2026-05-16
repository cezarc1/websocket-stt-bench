open! Core
open! Async

(** Start the stock OCaml Async gateway. *)

val start : Config.t -> unit Deferred.t
