module P = Stt_ocaml_oxcaml_epoll.Protocol

let test_accept_key_matches_rfc () =
  let got = Stt_ocaml_oxcaml_epoll.Handshake.accept_key "dGhlIHNhbXBsZSBub25jZQ==" in
  Alcotest.(check string) "accept" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" got
;;

let test_start_message_rejects_unknown_fields () =
  match P.start_message_ok {|{"type":"start","extra":1}|} with
  | Ok () -> Alcotest.fail "expected unknown-field rejection"
  | Error _ -> ()
;;

let test_partial_serializes_wire_shape () =
  let partial : P.partial =
    { oldest_frame_seq = 1
    ; newest_frame_seq = 50
    ; frames = 50
    ; rms = 1.5
    ; zero_crossings = 2
    ; checksum = 3
    ; samples = 1280
    ; transcript = "now"
    ; audio_bytes = 32000
    ; cpu_passes = 4
    ; model_delay_ms = 75
    ; flush_lateness_ms = 2.25
    }
  in
  match Yojson.Safe.from_string (P.partial_to_string partial) with
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    Alcotest.(check (list string))
      "keys"
      [ "audio_bytes"
      ; "checksum"
      ; "cpu_passes"
      ; "flush_lateness_ms"
      ; "frames"
      ; "inflight_model_jobs"
      ; "model_delay_ms"
      ; "newest_frame_seq"
      ; "oldest_frame_seq"
      ; "rms"
      ; "samples"
      ; "transcript"
      ; "type"
      ; "zero_crossings"
      ]
      keys
  | _ -> Alcotest.fail "partial must be a JSON object"
;;

let test_partial_writer_matches_string_serializer () =
  let partial : P.partial =
    { oldest_frame_seq = 1
    ; newest_frame_seq = 50
    ; frames = 50
    ; rms = 1.5
    ; zero_crossings = 2
    ; checksum = 3
    ; samples = 1280
    ; transcript = "now"
    ; audio_bytes = 32000
    ; cpu_passes = 4
    ; model_delay_ms = 75
    ; flush_lateness_ms = 2.25
    }
  in
  let out = Buffer.create 256 in
  let writer : P.json_writer =
    { add_string = (fun s -> Buffer.add_string out s)
    ; add_char = (fun c -> Buffer.add_char out c)
    }
  in
  P.write_partial_json writer partial;
  Alcotest.(check string) "json" (P.partial_to_string partial) (Buffer.contents out)
;;

let test_error_writer_matches_string_serializer () =
  let err : P.error =
    { stage = P.Inference_request
    ; kind = P.Timeout
    ; message = "slow"
    ; oldest_frame_seq = 1
    ; newest_frame_seq = 2
    ; frames = 2
    ; audio_bytes = 1280
    ; oldest_age_ms = 20.0
    ; newest_age_ms = 10.0
    ; flush_lateness_ms = 1.25
    ; inference_elapsed_ms = Some 2000.0
    ; inflight_gateway_batches = 1
    ; gateway_buffer_frames = 3
    ; inference_status = None
    ; retryable = true
    }
  in
  let out = Buffer.create 384 in
  let writer : P.json_writer =
    { add_string = (fun s -> Buffer.add_string out s)
    ; add_char = (fun c -> Buffer.add_char out c)
    }
  in
  P.write_error_json writer err;
  Alcotest.(check string) "json" (P.error_to_string err) (Buffer.contents out)
;;

let test_websocket_parses_masked_binary_frame () =
  let payload = Bytes.init 640 (fun i -> Char.chr (i land 0xff)) in
  let mask = "\001\002\003\004" in
  let frame = Bytes.create (2 + 2 + 4 + 640) in
  Bytes.set frame 0 (Char.chr 0x82);
  Bytes.set frame 1 (Char.chr (0x80 lor 126));
  Bytes.set_uint16_be frame 2 640;
  Bytes.blit_string mask 0 frame 4 4;
  for i = 0 to 639 do
    let b = Char.code (Bytes.get payload i) lxor Char.code mask.[i land 3] in
    Bytes.set frame (8 + i) (Char.chr b)
  done;
  match Stt_ocaml_oxcaml_epoll.Ws.parse_one frame ~pos:0 ~len:(Bytes.length frame) with
  | Ok (Some ({ opcode = Binary; payload = parsed }, next)) ->
    Alcotest.(check int) "next" (Bytes.length frame) next;
    Alcotest.(check string) "payload" (Bytes.unsafe_to_string payload) parsed
  | Ok _ -> Alcotest.fail "expected a complete binary frame"
  | Error e -> Alcotest.fail e
;;

let test_websocket_rejects_negative_64_bit_length () =
  let frame = Bytes.make 14 '\000' in
  Bytes.set frame 0 (Char.chr 0x82);
  Bytes.set frame 1 (Char.chr (0x80 lor 127));
  Bytes.set_int64_be frame 2 Int64.min_int;
  Bytes.blit_string "\001\002\003\004" 0 frame 10 4;
  match Stt_ocaml_oxcaml_epoll.Ws.parse_one frame ~pos:0 ~len:(Bytes.length frame) with
  | Error "frame too large" -> ()
  | Error message -> Alcotest.failf "unexpected error: %s" message
  | Ok None -> Alcotest.fail "expected oversized frame rejection"
  | Ok (Some _) -> Alcotest.fail "negative 64-bit length must not parse"
;;

let test_mask_copy_unmasked_640_preserves_offsets () =
  let payload = Bytes.init 640 (fun i -> Char.chr (i * 17 land 0xff)) in
  let mask = Bytes.of_string "\017\034\051\068" in
  let src = Bytes.make (11 + 640 + 5) '\000' in
  let dst = Bytes.make (7 + 640 + 3) '\255' in
  Bytes.blit mask 0 src 3 4;
  for i = 0 to 639 do
    let b = Char.code (Bytes.get payload i) lxor Char.code (Bytes.get mask (i land 3)) in
    Bytes.set src (11 + i) (Char.chr b)
  done;
  Stt_ocaml_oxcaml_epoll.Mask.copy_unmasked_640
    src
    ~payload_pos:11
    ~mask_pos:3
    dst
    ~dst_pos:7;
  Alcotest.(check string)
    "payload"
    (Bytes.unsafe_to_string payload)
    (Bytes.sub_string dst 7 640);
  Alcotest.(check char) "prefix untouched" '\255' (Bytes.get dst 6);
  Alcotest.(check char) "suffix untouched" '\255' (Bytes.get dst (7 + 640))
;;

let test_websocket_writes_frame_into_existing_buffer () =
  let payload = String.make 130 'x' in
  let expected = Stt_ocaml_oxcaml_epoll.Ws.text payload in
  let out = Bytes.make (String.length expected + 8) '\000' in
  let wrote = Stt_ocaml_oxcaml_epoll.Ws.write_frame Text payload out 4 in
  Alcotest.(check int) "wrote" (String.length expected) wrote;
  Alcotest.(check string) "frame" expected (Bytes.sub_string out 4 wrote);
  Alcotest.(check char) "prefix untouched" '\000' (Bytes.get out 3);
  Alcotest.(check char) "suffix untouched" '\000' (Bytes.get out (4 + wrote))
;;

let test_http_response_parser_finds_complete_body () =
  let response =
    Bytes.of_string
      "HTTP/1.1 200 OK\r\n\
       Date: now\r\n\
       Content-Length: 13\r\n\
       Connection: keep-alive\r\n\
       \r\n\
       {\"ok\":true}!!trailing"
  in
  match
    Stt_ocaml_oxcaml_epoll.Http_response.parse response ~len:(Bytes.length response)
  with
  | None -> Alcotest.fail "expected complete response"
  | Some parsed ->
    Alcotest.(check int) "status" 200 parsed.status;
    Alcotest.(check int) "body_len" 13 parsed.body_len;
    Alcotest.(check string)
      "body"
      "{\"ok\":true}!!"
      (Bytes.sub_string response parsed.body_pos parsed.body_len)
;;

let test_http_response_parser_waits_for_body () =
  let response = Bytes.of_string "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe" in
  match
    Stt_ocaml_oxcaml_epoll.Http_response.parse response ~len:(Bytes.length response)
  with
  | None -> ()
  | Some _ -> Alcotest.fail "partial response must not parse"
;;

let test_http_request_writer_matches_inference_header () =
  let host = "stt-inference-server.stt-bench.svc.cluster.local" in
  let expected =
    "POST /infer HTTP/1.1\r\n\
     Host: stt-inference-server.stt-bench.svc.cluster.local:9000\r\n\
     x-cpu-passes: 4\r\n\
     Content-Type: application/octet-stream\r\n\
     Content-Length: 32000\r\n\
     Connection: keep-alive\r\n\
     \r\n"
  in
  let out = Bytes.make (String.length expected + 8) '\000' in
  let wrote =
    Stt_ocaml_oxcaml_epoll.Http_request.write_infer_header
      ~host
      ~port:9000
      ~cpu_passes:4
      ~body_len:32000
      out
      3
  in
  Alcotest.(check int) "wrote" (String.length expected) wrote;
  Alcotest.(check int)
    "header_len"
    (String.length expected)
    (Stt_ocaml_oxcaml_epoll.Http_request.infer_header_len
       ~host
       ~port:9000
       ~cpu_passes:4
       ~body_len:32000);
  Alcotest.(check string) "header" expected (Bytes.sub_string out 3 wrote);
  Alcotest.(check char) "prefix untouched" '\000' (Bytes.get out 2);
  Alcotest.(check char) "suffix untouched" '\000' (Bytes.get out (3 + wrote))
;;

let test_infer_response_parses_canonical_bytes () =
  let body =
    Bytes.of_string
      {|xx{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}yy|}
  in
  let pos = 2 in
  let len = Bytes.length body - 4 in
  match P.infer_response_of_bytes body ~pos ~len with
  | Error message -> Alcotest.fail message
  | Ok infer ->
    Alcotest.(check (float 1e-6)) "rms" 1.5 infer.rms;
    Alcotest.(check int) "zero_crossings" 2 infer.zero_crossings;
    Alcotest.(check int) "checksum" 3 infer.checksum;
    Alcotest.(check int) "samples" 1280 infer.samples;
    Alcotest.(check string) "transcript" "now" infer.transcript;
    Alcotest.(check int) "audio_bytes" 640 infer.audio_bytes
;;

let test_infer_response_bytes_rejects_unknown_field () =
  let body =
    Bytes.of_string
      {|{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640,"surprise":true}|}
  in
  match P.infer_response_of_bytes body ~pos:0 ~len:(Bytes.length body) with
  | Ok _ -> Alcotest.fail "expected unknown-field rejection"
  | Error _ -> ()
;;

let test_int_stack_recycles_slots_without_lists () =
  let stack = Stt_ocaml_oxcaml_epoll.Int_stack.of_init 3 Fun.id in
  Alcotest.(check int) "length" 3 (Stt_ocaml_oxcaml_epoll.Int_stack.length stack);
  Alcotest.(check (option int))
    "pop first"
    (Some 0)
    (Stt_ocaml_oxcaml_epoll.Int_stack.pop stack);
  Alcotest.(check (option int))
    "pop second"
    (Some 1)
    (Stt_ocaml_oxcaml_epoll.Int_stack.pop stack);
  Stt_ocaml_oxcaml_epoll.Int_stack.push stack 42;
  Alcotest.(check int)
    "length after push"
    2
    (Stt_ocaml_oxcaml_epoll.Int_stack.length stack);
  Alcotest.(check (option int))
    "recycled first"
    (Some 42)
    (Stt_ocaml_oxcaml_epoll.Int_stack.pop stack);
  Alcotest.(check (option int))
    "remaining"
    (Some 2)
    (Stt_ocaml_oxcaml_epoll.Int_stack.pop stack);
  Alcotest.(check (option int)) "empty" None (Stt_ocaml_oxcaml_epoll.Int_stack.pop stack)
;;

let test_timer_heap_orders_and_reuses_event () =
  let heap = Stt_ocaml_oxcaml_epoll.Timer_heap.create 2 in
  let event = Stt_ocaml_oxcaml_epoll.Timer_heap.create_event () in
  Stt_ocaml_oxcaml_epoll.Timer_heap.push heap ~at_ms:20.0 ~token:2 ~kind:1 ~gen:0;
  Stt_ocaml_oxcaml_epoll.Timer_heap.push heap ~at_ms:10.0 ~token:4 ~kind:1 ~gen:0;
  Stt_ocaml_oxcaml_epoll.Timer_heap.push heap ~at_ms:10.0 ~token:3 ~kind:2 ~gen:0;
  Alcotest.(check int) "length" 3 (Stt_ocaml_oxcaml_epoll.Timer_heap.length heap);
  Alcotest.(check (option (float 0.0001)))
    "peek"
    (Some 10.0)
    (Stt_ocaml_oxcaml_epoll.Timer_heap.peek_at_ms heap);
  Alcotest.(check bool)
    "pop first"
    true
    (Stt_ocaml_oxcaml_epoll.Timer_heap.pop_into heap event);
  Alcotest.(check int) "first token" 3 event.token;
  Alcotest.(check int) "first kind" 2 event.kind;
  Alcotest.(check bool)
    "pop second"
    true
    (Stt_ocaml_oxcaml_epoll.Timer_heap.pop_into heap event);
  Alcotest.(check int) "second token" 4 event.token;
  Alcotest.(check bool)
    "pop third"
    true
    (Stt_ocaml_oxcaml_epoll.Timer_heap.pop_into heap event);
  Alcotest.(check int) "third token" 2 event.token;
  Alcotest.(check bool)
    "empty"
    false
    (Stt_ocaml_oxcaml_epoll.Timer_heap.pop_into heap event)
;;

let () =
  Alcotest.run
    "stt-ocaml-oxcaml-epoll"
    [ ( "common"
      , [ Alcotest.test_case "accept key matches RFC" `Quick test_accept_key_matches_rfc
        ; Alcotest.test_case
            "start rejects unknown fields"
            `Quick
            test_start_message_rejects_unknown_fields
        ; Alcotest.test_case
            "partial serializes wire shape"
            `Quick
            test_partial_serializes_wire_shape
        ; Alcotest.test_case
            "partial writer matches string serializer"
            `Quick
            test_partial_writer_matches_string_serializer
        ; Alcotest.test_case
            "error writer matches string serializer"
            `Quick
            test_error_writer_matches_string_serializer
        ; Alcotest.test_case
            "websocket parses masked binary frame"
            `Quick
            test_websocket_parses_masked_binary_frame
        ; Alcotest.test_case
            "websocket rejects negative 64-bit length"
            `Quick
            test_websocket_rejects_negative_64_bit_length
        ; Alcotest.test_case
            "mask copy unmasked 640 preserves offsets"
            `Quick
            test_mask_copy_unmasked_640_preserves_offsets
        ; Alcotest.test_case
            "websocket writes frame into existing buffer"
            `Quick
            test_websocket_writes_frame_into_existing_buffer
        ; Alcotest.test_case
            "http response parser finds complete body"
            `Quick
            test_http_response_parser_finds_complete_body
        ; Alcotest.test_case
            "http response parser waits for body"
            `Quick
            test_http_response_parser_waits_for_body
        ; Alcotest.test_case
            "http request writer matches inference header"
            `Quick
            test_http_request_writer_matches_inference_header
        ; Alcotest.test_case
            "infer response parses canonical bytes"
            `Quick
            test_infer_response_parses_canonical_bytes
        ; Alcotest.test_case
            "infer response bytes rejects unknown field"
            `Quick
            test_infer_response_bytes_rejects_unknown_field
        ; Alcotest.test_case
            "int stack recycles slots without lists"
            `Quick
            test_int_stack_recycles_slots_without_lists
        ; Alcotest.test_case
            "timer heap orders and reuses event"
            `Quick
            test_timer_heap_orders_and_reuses_event
        ] )
    ]
;;
