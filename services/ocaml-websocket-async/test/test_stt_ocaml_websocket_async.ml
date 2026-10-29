open! Core
open! Async
module P = Stt_ocaml_websocket_async.Protocol
module S = Stt_ocaml_websocket_async.Session
module Wf = Stt_ocaml_websocket_async.Websocket_frame
module Wh = Stt_ocaml_websocket_async.Websocket_handshake

let test_config =
  { Stt_ocaml_websocket_async.Config.port = 9100
  ; inference_host = "127.0.0.1"
  ; inference_port = 9000
  ; inference_http_clients = 4
  ; worker_threads = 1
  ; flush_interval_ms = 1000
  ; flush_phase_jitter_ms = 0
  ; cpu_passes = 4
  ; model_delay_ms = 75
  }
;;

let test_start_message_accepts_canonical () =
  let json = Yojson.Safe.from_string {|{"type":"start"}|} in
  match P.Start_message.of_yojson json with
  | Ok msg -> Alcotest.(check string) "type" "start" msg.type_
  | Error msg -> Alcotest.fail msg
;;

let test_start_message_rejects_unknown_fields () =
  let json = Yojson.Safe.from_string {|{"type":"start","extra":true}|} in
  match P.Start_message.of_yojson json with
  | Ok _ -> Alcotest.fail "expected unknown field rejection"
  | Error _ -> ()
;;

let test_partial_serializes_required_shape () =
  let partial : P.Partial.t =
    { type_ = "partial"
    ; oldest_frame_seq = 1
    ; newest_frame_seq = 50
    ; frames = 50
    ; rms = 1.25
    ; zero_crossings = 7
    ; checksum = 42
    ; samples = 16000
    ; transcript = "ok"
    ; audio_bytes = 32000
    ; cpu_passes = 4
    ; model_delay_ms = 75
    ; flush_lateness_ms = 3.5
    ; inflight_model_jobs = 0
    }
  in
  let json = P.Partial.to_yojson partial in
  let obj =
    match json with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "partial did not serialize to object"
  in
  let keys = obj |> List.map ~f:fst |> List.sort ~compare:String.compare in
  Alcotest.(check int) "field count" 14 (List.length keys);
  List.iter
    [ "type"
    ; "oldest_frame_seq"
    ; "newest_frame_seq"
    ; "frames"
    ; "rms"
    ; "zero_crossings"
    ; "checksum"
    ; "samples"
    ; "transcript"
    ; "audio_bytes"
    ; "cpu_passes"
    ; "model_delay_ms"
    ; "flush_lateness_ms"
    ; "inflight_model_jobs"
    ]
    ~f:(fun key ->
      Alcotest.(check bool)
        (sprintf "has %s" key)
        true
        (List.mem keys key ~equal:String.equal))
;;

let test_session_accepts_exact_frame_size () =
  let _outbound_reader, outbound = Async.Pipe.create () in
  let inference = Stt_ocaml_websocket_async.Inference.create test_config in
  let session = S.create ~config:test_config ~inference ~outbound in
  match S.on_binary session (String.make P.frame_bytes '\000') with
  | S.Continue -> ()
  | S.Close _ -> Alcotest.fail "expected exact-size frame to be accepted"
;;

let test_session_rejects_wrong_frame_size () =
  let _outbound_reader, outbound = Async.Pipe.create () in
  let inference = Stt_ocaml_websocket_async.Inference.create test_config in
  let session = S.create ~config:test_config ~inference ~outbound in
  match S.on_binary session (String.make (P.frame_bytes - 1) '\000') with
  | S.Continue -> Alcotest.fail "expected undersized frame to close"
  | S.Close { code; reason = _ } -> Alcotest.(check int) "close code" 1003 code
;;

let test_runtime_version () =
  Alcotest.(check string)
    "expected stock OCaml"
    "5.4.1"
    Stt_ocaml_websocket_async.Runtime.expected_ocaml_version
;;

let test_websocket_accept_key_vector () =
  Alcotest.(check string)
    "accept key"
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (Wh.accept_key ~key:"dGhlIHNhbXBsZSBub25jZQ==")
;;

let test_websocket_upgrade_validation () =
  let req ?(version = "HTTP/1.1") ?(connection = "keep-alive, Upgrade") () =
    { Stt_ocaml_websocket_async.Http1.meth = "GET"
    ; path = "/ws/stt"
    ; version
    ; headers =
        [ "upgrade", "websocket"
        ; "connection", connection
        ; "sec-websocket-version", "13"
        ; "sec-websocket-key", "key"
        ]
    }
  in
  Alcotest.(check (option string)) "valid" (Some "key") (Wh.upgrade_key (req ()));
  Alcotest.(check (option string))
    "reject http/1.0"
    None
    (Wh.upgrade_key (req ~version:"HTTP/1.0" ()));
  Alcotest.(check (option string))
    "reject substring token"
    None
    (Wh.upgrade_key (req ~connection:"keep-alive, x-upgrade" ()))
;;

let test_server_text_frame_write_shape () =
  let pipe_r, pipe_w = Core_unix.pipe () in
  let writer =
    Async.Writer.create (Async.Fd.create Fifo pipe_w (Info.of_string "ws-test-w"))
  in
  Async.Thread_safe.block_on_async_exn (fun () ->
    Wf.write writer (Wf.text "ok") >>= fun () -> Writer.close writer);
  let got = Bytes.create 4 in
  let reader = Reader.create (Async.Fd.create Fifo pipe_r (Info.of_string "ws-test-r")) in
  let read =
    Async.Thread_safe.block_on_async_exn (fun () ->
      Reader.really_read reader ~len:4 got
      >>| function
      | `Ok -> 4
      | `Eof n -> n)
  in
  Async.Thread_safe.block_on_async_exn (fun () -> Reader.close reader);
  Alcotest.(check int) "bytes read" 4 read;
  Alcotest.(check string) "wire bytes" "\x81\x02ok" (Bytes.to_string got)
;;

(* ---- Connection-level tests: drive [Websocket_connection.run] over Unix pipes with
   hand-built masked client frames, then decode the server's (unmasked) reply frames. The
   inference port is unused; every test closes well before the first 1 s flush. *)

module Wc = Stt_ocaml_websocket_async.Websocket_connection

let client_frame ?(fin = true) ?(rsv = 0) ~opcode payload =
  let len = String.length payload in
  let mask = "\x11\x22\x33\x44" in
  let b = Buffer.create (len + 14) in
  Buffer.add_char b (Char.of_int_exn ((if fin then 0x80 else 0) lor rsv lor opcode));
  if len < 126
  then Buffer.add_char b (Char.of_int_exn (0x80 lor len))
  else (
    Buffer.add_char b (Char.of_int_exn (0x80 lor 126));
    Buffer.add_char b (Char.of_int_exn (len lsr 8));
    Buffer.add_char b (Char.of_int_exn (len land 0xFF)));
  Buffer.add_string b mask;
  String.iteri payload ~f:(fun i c ->
    Buffer.add_char b (Char.of_int_exn (Char.to_int c lxor Char.to_int mask.[i land 3])));
  Buffer.contents b
;;

let start_frame = client_frame ~opcode:1 {|{"type":"start"}|}
let close_frame = client_frame ~opcode:8 ""

(* Server frames as (opcode, payload); server frames are short and unmasked. *)
let parse_server_frames s =
  let rec go pos acc =
    if pos >= String.length s
    then List.rev acc
    else (
      let opcode = Char.to_int s.[pos] land 0x0F in
      let len = Char.to_int s.[pos + 1] land 0x7F in
      go (pos + 2 + len) ((opcode, String.sub s ~pos:(pos + 2) ~len) :: acc))
  in
  go 0 []
;;

let run_connection input =
  let in_r, in_w = Core_unix.pipe () in
  let out_r, out_w = Core_unix.pipe () in
  let written = Core_unix.write_substring in_w ~buf:input in
  assert (written = String.length input);
  Core_unix.close in_w;
  Async.Thread_safe.block_on_async_exn (fun () ->
    let reader = Reader.create (Fd.create Fifo in_r (Info.of_string "ws-in")) in
    let writer = Writer.create (Fd.create Fifo out_w (Info.of_string "ws-out")) in
    let inference = Stt_ocaml_websocket_async.Inference.create test_config in
    let%bind () = Wc.run ~config:test_config ~inference ~reader ~writer in
    let%bind () = Writer.close writer in
    Reader.close reader);
  Async.Thread_safe.block_on_async_exn (fun () ->
    let reader = Reader.create (Fd.create Fifo out_r (Info.of_string "ws-out-r")) in
    let%bind s = Reader.contents reader in
    let%map () = Reader.close reader in
    parse_server_frames s)
;;

let close_code frames =
  match List.last frames with
  | Some (8, payload) when String.length payload = 2 ->
    (Char.to_int payload.[0] lsl 8) lor Char.to_int payload.[1]
  | _ -> Alcotest.fail "server did not end with a close frame carrying a code"
;;

let check_close name expected input =
  Alcotest.(check int) name expected (close_code (run_connection input))
;;

let pcm = String.init P.frame_bytes ~f:(fun i -> Char.of_int_exn (i land 0xFF))

let test_fragmented_messages_reassemble () =
  (* Fragmented start with a ping interleaved, then a 640-byte binary frame split 300 +
     340. If either were mis-assembled the server would close 1002 / 1003, not 1000. *)
  let input =
    String.concat
      [ client_frame ~fin:false ~opcode:1 {|{"type":|}
      ; client_frame ~opcode:9 "hi"
      ; client_frame ~opcode:0 {|"start"}|}
      ; client_frame ~fin:false ~opcode:2 (String.prefix pcm 300)
      ; client_frame ~opcode:0 (String.drop_prefix pcm 300)
      ; close_frame
      ]
  in
  let frames = run_connection input in
  Alcotest.(check (list int)) "pong then close" [ 10; 8 ] (List.map frames ~f:fst);
  Alcotest.(check string) "pong echoes ping" "hi" (snd (List.hd_exn frames));
  Alcotest.(check int) "normal close" 1000 (close_code frames)
;;

let test_fragmented_wrong_size_closes_1003 () =
  check_close
    "reassembled 641 bytes"
    1003
    (String.concat
       [ start_frame
       ; client_frame ~fin:false ~opcode:2 (String.prefix pcm 300)
       ; client_frame ~opcode:0 (String.drop_prefix pcm 300 ^ "x")
       ])
;;

let test_fragmentation_violations_close_1002 () =
  check_close
    "continuation without a message"
    1002
    (start_frame ^ client_frame ~opcode:0 pcm);
  check_close
    "new data frame mid-message"
    1002
    (String.concat
       [ start_frame
       ; client_frame ~fin:false ~opcode:2 (String.prefix pcm 300)
       ; client_frame ~opcode:2 pcm
       ])
;;

let test_reserved_bits_close_1002 () =
  check_close "RSV1 set" 1002 (start_frame ^ client_frame ~rsv:0x40 ~opcode:2 pcm)
;;

let test_negative_64bit_length_closes_1002 () =
  (* 127-length with the MSB set: must be rejected, not passed to [Bytes.create]. *)
  check_close
    "64-bit length MSB set"
    1002
    (start_frame ^ "\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00\x11\x22\x33\x44")
;;

let test_invalid_first_message_closes_1002 () =
  check_close "non-JSON" 1002 (client_frame ~opcode:1 "not-json");
  check_close "wrong type" 1002 (client_frame ~opcode:1 {|{"type":"stop"}|});
  check_close "binary first" 1002 (client_frame ~opcode:2 pcm)
;;

let test_invalid_frame_sizes_close_1003 () =
  List.iter
    [ 0; 10; P.frame_bytes - 1; P.frame_bytes + 1 ]
    ~f:(fun size ->
      check_close
        (sprintf "%d-byte frame" size)
        1003
        (start_frame ^ client_frame ~opcode:2 (String.make size '\000')))
;;

(* A peer that vanished: the server's output pipe has no reader, so the pong write hits
   EPIPE. [Writer.flushed] would never become determined there, wedging the receive loop
   (and leaking the session) instead of letting it see the input EOF and tear down. *)
let test_vanished_peer_tears_down () =
  let in_r, in_w = Core_unix.pipe () in
  let out_r, out_w = Core_unix.pipe () in
  Core_unix.close out_r;
  let input = start_frame ^ client_frame ~opcode:9 "hi" in
  let written = Core_unix.write_substring in_w ~buf:input in
  assert (written = String.length input);
  Core_unix.close in_w;
  let outcome =
    Async.Thread_safe.block_on_async_exn (fun () ->
      let reader = Reader.create (Fd.create Fifo in_r (Info.of_string "ws-in")) in
      let writer = Writer.create (Fd.create Fifo out_w (Info.of_string "ws-out")) in
      (* Like a vanished TCP peer under Tcp.Server: report, don't raise, on EPIPE. *)
      Writer.set_raise_when_consumer_leaves writer false;
      let inference = Stt_ocaml_websocket_async.Inference.create test_config in
      let%bind outcome =
        Clock_ns.with_timeout
          (Time_ns.Span.of_sec 3.)
          (Wc.run ~config:test_config ~inference ~reader ~writer)
      in
      let%bind () = Writer.close ~force_close:Deferred.unit writer in
      let%map () = Reader.close reader in
      outcome)
  in
  match outcome with
  | `Result () -> ()
  | `Timeout -> Alcotest.fail "connection never tore down after the peer vanished"
;;

let () =
  Command_unix.run
    (Command.basic
       ~summary:"stock OCaml gateway tests"
       (Command.Param.return (fun () ->
          Alcotest.run
            "stt_ocaml_websocket_async"
            [ ( "protocol"
              , [ Alcotest.test_case
                    "Start_message: accepts canonical"
                    `Quick
                    test_start_message_accepts_canonical
                ; Alcotest.test_case
                    "Start_message: rejects unknown fields"
                    `Quick
                    test_start_message_rejects_unknown_fields
                ; Alcotest.test_case
                    "Partial: serializes required shape"
                    `Quick
                    test_partial_serializes_required_shape
                ; Alcotest.test_case
                    "Session: accepts exact frame size"
                    `Quick
                    test_session_accepts_exact_frame_size
                ; Alcotest.test_case
                    "Session: rejects wrong frame size"
                    `Quick
                    test_session_rejects_wrong_frame_size
                ] )
            ; ( "runtime"
              , [ Alcotest.test_case
                    "expected stock OCaml version constant"
                    `Quick
                    test_runtime_version
                ] )
            ; ( "websocket"
              , [ Alcotest.test_case
                    "accept key matches RFC vector"
                    `Quick
                    test_websocket_accept_key_vector
                ; Alcotest.test_case
                    "upgrade validation is token/version strict"
                    `Quick
                    test_websocket_upgrade_validation
                ; Alcotest.test_case
                    "server text frame writes unmasked payload"
                    `Quick
                    test_server_text_frame_write_shape
                ] )
            ; ( "connection"
              , [ Alcotest.test_case
                    "fragmented messages reassemble around control frames"
                    `Quick
                    test_fragmented_messages_reassemble
                ; Alcotest.test_case
                    "reassembled wrong-size binary closes 1003"
                    `Quick
                    test_fragmented_wrong_size_closes_1003
                ; Alcotest.test_case
                    "fragmentation violations close 1002"
                    `Quick
                    test_fragmentation_violations_close_1002
                ; Alcotest.test_case
                    "reserved bits close 1002"
                    `Quick
                    test_reserved_bits_close_1002
                ; Alcotest.test_case
                    "negative 64-bit length closes 1002"
                    `Quick
                    test_negative_64bit_length_closes_1002
                ; Alcotest.test_case
                    "invalid first message closes 1002"
                    `Quick
                    test_invalid_first_message_closes_1002
                ; Alcotest.test_case
                    "invalid frame sizes close 1003"
                    `Quick
                    test_invalid_frame_sizes_close_1003
                ; Alcotest.test_case
                    "vanished peer still tears down"
                    `Quick
                    test_vanished_peer_tears_down
                ] )
            ])))
;;
