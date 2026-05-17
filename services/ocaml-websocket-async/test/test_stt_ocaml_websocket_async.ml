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
            ])))
;;
