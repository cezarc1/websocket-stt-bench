let frame_bytes = 640
let partial_type = "partial"
let error_type = "error"

type infer_response =
  { rms : float
  ; zero_crossings : int
  ; checksum : int
  ; samples : int
  ; transcript : string
  ; audio_bytes : int
  }

type partial =
  { oldest_frame_seq : int
  ; newest_frame_seq : int
  ; frames : int
  ; rms : float
  ; zero_crossings : int
  ; checksum : int
  ; samples : int
  ; transcript : string
  ; audio_bytes : int
  ; cpu_passes : int
  ; model_delay_ms : int
  ; flush_lateness_ms : float
  }

type error_stage =
  | Inference_request
  | Inference_response_parse

type error_kind =
  | Timeout
  | Connection_reset
  | Http_5xx
  | Http_429
  | Parse_error

type error =
  { stage : error_stage
  ; kind : error_kind
  ; message : string
  ; oldest_frame_seq : int
  ; newest_frame_seq : int
  ; frames : int
  ; audio_bytes : int
  ; oldest_age_ms : float
  ; newest_age_ms : float
  ; flush_lateness_ms : float
  ; inference_elapsed_ms : float option
  ; inflight_gateway_batches : int
  ; gateway_buffer_frames : int
  ; inference_status : int option
  ; retryable : bool
  }

let stage_to_wire = function
  | Inference_request -> "inference_request"
  | Inference_response_parse -> "inference_response_parse"
;;

let kind_to_wire = function
  | Timeout -> "timeout"
  | Connection_reset -> "connection_reset"
  | Http_5xx -> "http_5xx"
  | Http_429 -> "http_429"
  | Parse_error -> "parse_error"
;;

let start_message_ok s =
  match Yojson.Safe.from_string s with
  | exception exn -> Error (Printexc.to_string exn)
  | `Assoc [ ("type", `String "start") ] -> Ok ()
  | `Assoc fields when List.exists (fun (k, _) -> k = "type") fields ->
    Error "Start_message: rejected unknown fields"
  | `Assoc _ -> Error "Start_message: missing required \"type\" field"
  | _ -> Error "Start_message: expected JSON object"
;;

type json_writer =
  { add_string : string -> unit
  ; add_char : char -> unit
  }

let json_string w s =
  w.add_char '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> w.add_string "\\\""
      | '\\' -> w.add_string "\\\\"
      | '\n' -> w.add_string "\\n"
      | '\r' -> w.add_string "\\r"
      | '\t' -> w.add_string "\\t"
      | c when Char.code c < 0x20 -> w.add_string (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> w.add_char c)
    s;
  w.add_char '"'
;;

let add_float w f = w.add_string (Printf.sprintf "%.17g" f)
let add_int w i = w.add_string (string_of_int i)
let add_bool w v = w.add_string (if v then "true" else "false")

let write_partial_json w (p : partial) =
  w.add_string {|{"type":|};
  json_string w partial_type;
  w.add_string {|,"oldest_frame_seq":|};
  add_int w p.oldest_frame_seq;
  w.add_string {|,"newest_frame_seq":|};
  add_int w p.newest_frame_seq;
  w.add_string {|,"frames":|};
  add_int w p.frames;
  w.add_string {|,"rms":|};
  add_float w p.rms;
  w.add_string {|,"zero_crossings":|};
  add_int w p.zero_crossings;
  w.add_string {|,"checksum":|};
  add_int w p.checksum;
  w.add_string {|,"samples":|};
  add_int w p.samples;
  w.add_string {|,"transcript":|};
  json_string w p.transcript;
  w.add_string {|,"audio_bytes":|};
  add_int w p.audio_bytes;
  w.add_string {|,"cpu_passes":|};
  add_int w p.cpu_passes;
  w.add_string {|,"model_delay_ms":|};
  add_int w p.model_delay_ms;
  w.add_string {|,"flush_lateness_ms":|};
  add_float w p.flush_lateness_ms;
  w.add_string {|,"inflight_model_jobs":0}|}
;;

let option_float b = function
  | None -> b.add_string "null"
  | Some f -> add_float b f
;;

let option_int b = function
  | None -> b.add_string "null"
  | Some i -> add_int b i
;;

let write_error_json w (e : error) =
  w.add_string {|{"type":|};
  json_string w error_type;
  w.add_string {|,"stage":|};
  json_string w (stage_to_wire e.stage);
  w.add_string {|,"kind":|};
  json_string w (kind_to_wire e.kind);
  w.add_string {|,"message":|};
  json_string w e.message;
  w.add_string {|,"oldest_frame_seq":|};
  add_int w e.oldest_frame_seq;
  w.add_string {|,"newest_frame_seq":|};
  add_int w e.newest_frame_seq;
  w.add_string {|,"frames":|};
  add_int w e.frames;
  w.add_string {|,"audio_bytes":|};
  add_int w e.audio_bytes;
  w.add_string {|,"oldest_age_ms":|};
  add_float w e.oldest_age_ms;
  w.add_string {|,"newest_age_ms":|};
  add_float w e.newest_age_ms;
  w.add_string {|,"flush_lateness_ms":|};
  add_float w e.flush_lateness_ms;
  w.add_string {|,"inference_elapsed_ms":|};
  option_float w e.inference_elapsed_ms;
  w.add_string {|,"inflight_gateway_batches":|};
  add_int w e.inflight_gateway_batches;
  w.add_string {|,"gateway_buffer_frames":|};
  add_int w e.gateway_buffer_frames;
  w.add_string {|,"inference_status":|};
  option_int w e.inference_status;
  w.add_string {|,"retryable":|};
  add_bool w e.retryable;
  w.add_char '}'
;;

let writer_of_buffer b =
  { add_string = (fun s -> Buffer.add_string b s)
  ; add_char = (fun c -> Buffer.add_char b c)
  }
;;

let partial_to_string (p : partial) =
  let b = Buffer.create 256 in
  write_partial_json (writer_of_buffer b) p;
  Buffer.contents b
;;

let error_to_string (e : error) =
  let b = Buffer.create 384 in
  write_error_json (writer_of_buffer b) e;
  Buffer.contents b
;;

let assoc_find key fields = List.assoc_opt key fields

let read_int = function
  | `Int i -> Ok i
  | `Intlit s ->
    (try Ok (int_of_string s) with
     | Failure _ -> Error "expected integer")
  | _ -> Error "expected integer"
;;

let read_float = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "expected number"
;;

let read_string = function
  | `String s -> Ok s
  | _ -> Error "expected string"
;;

let bind r f =
  match r with
  | Ok v -> f v
  | Error _ as e -> e
;;

let infer_response_of_string s =
  match Yojson.Safe.from_string s with
  | exception exn -> Error (Printexc.to_string exn)
  | `Assoc fields ->
    let known =
      [ "rms"; "zero_crossings"; "checksum"; "samples"; "transcript"; "audio_bytes" ]
    in
    (match List.find_opt (fun (k, _) -> not (List.mem k known)) fields with
     | Some (k, _) -> Error ("Infer_response: rejected unknown field " ^ k)
     | None ->
       let find key reader =
         match assoc_find key fields with
         | None -> Error ("Infer_response: missing " ^ key)
         | Some value -> reader value
       in
       bind (find "rms" read_float) (fun rms ->
         bind (find "zero_crossings" read_int) (fun zero_crossings ->
           bind (find "checksum" read_int) (fun checksum ->
             bind (find "samples" read_int) (fun samples ->
               bind (find "transcript" read_string) (fun transcript ->
                 bind (find "audio_bytes" read_int) (fun audio_bytes ->
                   Ok { rms; zero_crossings; checksum; samples; transcript; audio_bytes })))))))
  | _ -> Error "Infer_response: expected JSON object"
;;

let starts_with_bytes b ~pos ~limit s =
  let len = String.length s in
  pos + len <= limit
  &&
  let rec loop i = i = len || (Bytes.get b (pos + i) = String.get s i && loop (i + 1)) in
  loop 0
;;

let parse_literal b ~pos ~limit s =
  if starts_with_bytes b ~pos ~limit s then Some (pos + String.length s) else None
;;

let parse_uint_bytes b ~pos ~limit =
  let rec loop i value =
    if i >= limit
    then i, value
    else (
      let code = Char.code (Bytes.get b i) in
      if code >= Char.code '0' && code <= Char.code '9'
      then loop (i + 1) ((value * 10) + code - Char.code '0')
      else i, value)
  in
  if pos >= limit
  then None
  else (
    let code = Char.code (Bytes.get b pos) in
    if code < Char.code '0' || code > Char.code '9'
    then None
    else (
      let next, value = loop pos 0 in
      Some (value, next)))
;;

let is_number_char = function
  | '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true
  | _ -> false
;;

let parse_float_bytes b ~pos ~limit =
  let rec loop i =
    if i < limit && is_number_char (Bytes.get b i) then loop (i + 1) else i
  in
  let next = loop pos in
  if next = pos
  then None
  else (
    match float_of_string (Bytes.sub_string b pos (next - pos)) with
    | value -> Some (value, next)
    | exception Failure _ -> None)
;;

let parse_simple_json_string b ~pos ~limit =
  if pos >= limit || Bytes.get b pos <> '"'
  then None
  else (
    let rec loop i =
      if i >= limit
      then None
      else (
        match Bytes.get b i with
        | '"' -> Some (Bytes.sub_string b (pos + 1) (i - pos - 1), i + 1)
        | '\\' -> None
        | _ -> loop (i + 1))
    in
    loop (pos + 1))
;;

let infer_response_of_bytes_fast b ~pos ~len =
  let limit = pos + len in
  if pos < 0 || len < 0 || limit > Bytes.length b
  then None
  else (
    let ( let* ) = Option.bind in
    let* pos = parse_literal b ~pos ~limit {|{"rms":|} in
    let* rms, pos = parse_float_bytes b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit {|,"zero_crossings":|} in
    let* zero_crossings, pos = parse_uint_bytes b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit {|,"checksum":|} in
    let* checksum, pos = parse_uint_bytes b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit {|,"samples":|} in
    let* samples, pos = parse_uint_bytes b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit {|,"transcript":|} in
    let* transcript, pos = parse_simple_json_string b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit {|,"audio_bytes":|} in
    let* audio_bytes, pos = parse_uint_bytes b ~pos ~limit in
    let* pos = parse_literal b ~pos ~limit "}" in
    if pos = limit
    then Some { rms; zero_crossings; checksum; samples; transcript; audio_bytes }
    else None)
;;

let infer_response_of_bytes b ~pos ~len =
  match infer_response_of_bytes_fast b ~pos ~len with
  | Some infer -> Ok infer
  | None -> infer_response_of_string (Bytes.sub_string b pos len)
;;
