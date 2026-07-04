type opcode =
  | Continuation
  | Text
  | Binary
  | Close
  | Ping
  | Pong
  | Other of int

type frame =
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

let get_u8 b i = Char.code (Bytes.get b i)

let parse_len b pos stop base_len =
  if base_len < 126
  then Ok (Some (base_len, pos))
  else if base_len = 126
  then if pos + 2 > stop then Ok None else Ok (Some (Bytes.get_uint16_be b pos, pos + 2))
  else if pos + 8 > stop
  then Ok None
  else (
    let full = Bytes.get_int64_be b pos in
    if full > Int64.of_int (1 lsl 30)
    then Error "frame too large"
    else Ok (Some (Int64.to_int full, pos + 8)))
;;

let parse_one b ~pos ~len =
  let stop = len in
  if pos + 2 > stop
  then Ok None
  else (
    let byte0 = get_u8 b pos in
    let byte1 = get_u8 b (pos + 1) in
    let fin = byte0 land 0x80 <> 0 in
    let opcode_int = byte0 land 0x0f in
    let opcode = opcode_of_int opcode_int in
    let masked = byte1 land 0x80 <> 0 in
    let base_len = byte1 land 0x7f in
    if not masked
    then Error "client frame not masked"
    else if opcode_int >= 8 && ((not fin) || base_len > 125)
    then Error "invalid control frame"
    else (
      match parse_len b (pos + 2) stop base_len with
      | Error _ as e -> e
      | Ok None -> Ok None
      | Ok (Some (payload_len, after_len)) ->
        let mask_pos = after_len in
        let payload_pos = mask_pos + 4 in
        if payload_pos + payload_len > stop
        then Ok None
        else (
          let out = Bytes.create payload_len in
          for i = 0 to payload_len - 1 do
            let m = get_u8 b (mask_pos + (i land 3)) in
            let v = get_u8 b (payload_pos + i) lxor m in
            Bytes.set out i (Char.chr v)
          done;
          Ok
            (Some
               ( { fin; opcode; payload = Bytes.unsafe_to_string out }
               , payload_pos + payload_len )))))
;;

let header_len payload_len =
  if payload_len < 126 then 2 else if payload_len < 65536 then 4 else 10
;;

let write_header opcode payload_len out pos =
  let opcode = opcode_to_int opcode in
  let header_len = header_len payload_len in
  Bytes.set out pos (Char.chr (0x80 lor opcode));
  if payload_len < 126
  then Bytes.set out (pos + 1) (Char.chr payload_len)
  else if payload_len < 65536
  then (
    Bytes.set out (pos + 1) (Char.chr 126);
    Bytes.set_uint16_be out (pos + 2) payload_len)
  else (
    Bytes.set out (pos + 1) (Char.chr 127);
    Bytes.set_int64_be out (pos + 2) (Int64.of_int payload_len));
  header_len
;;

let frame_to_string opcode payload =
  let payload_len = String.length payload in
  let header_len = header_len payload_len in
  let out = Bytes.create (header_len + payload_len) in
  ignore (write_header opcode payload_len out 0 : int);
  Bytes.blit_string payload 0 out header_len payload_len;
  Bytes.unsafe_to_string out
;;

let frame_len payload =
  let payload_len = String.length payload in
  header_len payload_len + payload_len
;;

let write_frame opcode payload out pos =
  let payload_len = String.length payload in
  let header_len = write_header opcode payload_len out pos in
  Bytes.blit_string payload 0 out (pos + header_len) payload_len;
  header_len + payload_len
;;

let text payload = frame_to_string Text payload
let pong payload = frame_to_string Pong payload

let close ?(code = 1000) () =
  let payload = Bytes.create 2 in
  Bytes.set_uint16_be payload 0 code;
  frame_to_string Close (Bytes.unsafe_to_string payload)
;;
