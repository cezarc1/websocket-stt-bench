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

type request =
  { meth : string
  ; path : string
  ; headers : (string * string) list
  }

let parse_request_line line =
  match String.split line ~on:' ' with
  | [ meth; path; _version ] -> Some (meth, path)
  | _ -> None
;;

let read_request reader =
  match%bind Reader.read_line reader with
  | `Eof -> return None
  | `Ok request_line ->
    (match parse_request_line request_line with
     | None -> return None
     | Some (meth, path) ->
       (match%map read_headers reader with
        | `Ok headers -> Some { meth; path; headers }
        (* Peer closed mid-headers: no headers; upgrade validation then rejects with 400,
           same as a malformed upgrade. *)
        | `Eof -> Some { meth; path; headers = [] }))
;;
