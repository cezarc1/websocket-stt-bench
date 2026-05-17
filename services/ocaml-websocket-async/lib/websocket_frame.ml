open! Core
open! Async

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

let opcode_of_int = function
  | 0 -> Continuation
  | 1 -> Text
  | 2 -> Binary
  | 8 -> Close
  | 9 -> Ping
  | 10 -> Pong
  | n -> Other n
;;

let opcode_to_int = function
  | Continuation -> 0
  | Text -> 1
  | Binary -> 2
  | Close -> 8
  | Ping -> 9
  | Pong -> 10
  | Other n -> n
;;

let read_byte reader =
  match%bind Reader.read_char reader with
  | `Eof -> return None
  | `Ok c -> return (Some (Char.to_int c))
;;

let read_bytes reader ~len =
  let buf = Bytes.create len in
  match%bind Reader.really_read reader ~len buf with
  | `Eof _ -> return None
  | `Ok -> return (Some buf)
;;

let parse_extended_length reader ~base_len =
  if base_len < 126
  then return (Some base_len)
  else if base_len = 126
  then (
    match%bind read_bytes reader ~len:2 with
    | None -> return None
    | Some b -> return (Some (Stdlib.Bytes.get_uint16_be b 0)))
  else (
    match%bind read_bytes reader ~len:8 with
    | None -> return None
    | Some b ->
      let full = Stdlib.Bytes.get_int64_be b 0 in
      if Int64.( > ) full (Int64.of_int (1 lsl 30))
      then return None
      else return (Some (Int64.to_int_exn full)))
;;

let unmask_inplace buf ~mask =
  let len = Bytes.length buf in
  for i = 0 to len - 1 do
    let m = Char.to_int (Bytes.unsafe_get mask (i land 3)) in
    let b = Char.to_int (Bytes.unsafe_get buf i) lxor m in
    Bytes.unsafe_set buf i (Char.unsafe_of_int b)
  done
;;

let read reader =
  match%bind read_byte reader with
  | None -> return `Eof
  | Some byte0 ->
    let fin = byte0 land 0x80 <> 0 in
    let opcode = opcode_of_int (byte0 land 0x0F) in
    (match%bind read_byte reader with
     | None -> return `Eof
     | Some byte1 ->
       let masked = byte1 land 0x80 <> 0 in
       let base_len = byte1 land 0x7F in
       if not masked
       then return (`Error "client frame not masked")
       else (
         match%bind parse_extended_length reader ~base_len with
         | None -> return (`Error "frame too large")
         | Some len ->
           let is_control = byte0 land 0x0F >= 0x8 in
           if is_control && (len > 125 || not fin)
           then return (`Error "invalid control frame")
           else (
             match%bind read_bytes reader ~len:4 with
             | None -> return `Eof
             | Some mask ->
               (match%bind read_bytes reader ~len with
                | None -> return `Eof
                | Some raw ->
                  unmask_inplace raw ~mask;
                  let payload =
                    Bytes.unsafe_to_string ~no_mutation_while_string_reachable:raw
                  in
                  return (`Ok { fin; opcode; payload })))))
;;

let write writer (t : t) =
  let payload_len = String.length t.payload in
  let byte0 = (if t.fin then 0x80 else 0) lor (opcode_to_int t.opcode land 0x0F) in
  let header =
    if payload_len < 126
    then (
      let h = Bytes.create 2 in
      Bytes.set h 0 (Char.of_int_exn byte0);
      Bytes.set h 1 (Char.of_int_exn payload_len);
      h)
    else if payload_len < 65536
    then (
      let h = Bytes.create 4 in
      Bytes.set h 0 (Char.of_int_exn byte0);
      Bytes.set h 1 (Char.of_int_exn 126);
      Stdlib.Bytes.set_uint16_be h 2 payload_len;
      h)
    else (
      let h = Bytes.create 10 in
      Bytes.set h 0 (Char.of_int_exn byte0);
      Bytes.set h 1 (Char.of_int_exn 127);
      Stdlib.Bytes.set_int64_be h 2 (Int64.of_int payload_len);
      h)
  in
  Writer.write_bytes writer header;
  Writer.write writer t.payload;
  Writer.flushed writer
;;

let text payload = { fin = true; opcode = Text; payload }
let binary payload = { fin = true; opcode = Binary; payload }
let pong payload = { fin = true; opcode = Pong; payload }

let close ?(code = 1000) () =
  let payload = Bytes.create 2 in
  Stdlib.Bytes.set_uint16_be payload 0 code;
  { fin = true; opcode = Close; payload = Bytes.to_string payload }
;;
