open! Core
open! Async

let read_headers reader =
  let rec loop acc =
    match%bind Reader.read_line reader with
    | `Eof -> return `Eof
    | `Ok "" -> return (`Ok (List.rev acc))
    | `Ok line ->
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> loop ((String.lowercase (String.strip k), String.strip v) :: acc)
       | None -> loop acc)
  in
  loop []
;;

let find headers k = List.Assoc.find headers ~equal:String.equal (String.lowercase k)
