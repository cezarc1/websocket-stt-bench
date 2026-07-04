open! Core
module P = Stt_ocaml_oxcaml.Protocol

let yojson_of_string = Yojson.Safe.from_string

let test_start_message_accepts_canonical () =
  match P.Start_message.of_yojson (yojson_of_string {|{"type":"start"}|}) with
  | Ok msg -> Alcotest.(check string) "type" "start" msg.type_
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e
;;

let test_start_message_rejects_unknown_field () =
  match P.Start_message.of_yojson (yojson_of_string {|{"type":"start","extra":1}|}) with
  | Ok _ -> Alcotest.fail "expected unknown-field rejection"
  | Error _ -> ()
;;

let test_start_message_rejects_missing_type () =
  match P.Start_message.of_yojson (yojson_of_string {|{}|}) with
  | Ok _ -> Alcotest.fail "expected error on empty object"
  | Error _ -> ()
;;

let test_infer_response_decodes_canonical () =
  let json =
    yojson_of_string
      {|{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}|}
  in
  match P.Infer_response.of_yojson json with
  | Error e -> Alcotest.failf "expected Ok, got %s" e
  | Ok t ->
    Alcotest.(check (float 1e-6)) "rms" 1.5 t.rms;
    Alcotest.(check int) "zero_crossings" 2 t.zero_crossings;
    Alcotest.(check int) "checksum" 3 t.checksum;
    Alcotest.(check int) "samples" 1280 t.samples;
    Alcotest.(check string) "transcript" "now" t.transcript;
    Alcotest.(check int) "audio_bytes" 640 t.audio_bytes
;;

let test_infer_response_rejects_unknown_field () =
  let json =
    yojson_of_string
      {|{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640,"surprise":true}|}
  in
  match P.Infer_response.of_yojson json with
  | Ok _ -> Alcotest.fail "expected unknown-field rejection"
  | Error _ -> ()
;;

let test_partial_serializes_exact_field_set () =
  let partial : P.Partial.t =
    { type_ = "partial"
    ; oldest_frame_seq = 1
    ; newest_frame_seq = 50
    ; frames = 50
    ; rms = 2425.5
    ; zero_crossings = 7
    ; checksum = 1745339397
    ; samples = 1280
    ; transcript = "now"
    ; audio_bytes = 640
    ; cpu_passes = 4
    ; model_delay_ms = 75
    ; flush_lateness_ms = 35.0
    ; inflight_model_jobs = 0
    }
  in
  match P.Partial.to_yojson partial with
  | `Assoc fields ->
    let actual_keys = List.map fields ~f:fst |> List.sort ~compare:String.compare in
    let expected_keys =
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
      |> List.sort ~compare:String.compare
    in
    Alcotest.(check (list string)) "partial keys" expected_keys actual_keys
  | _ -> Alcotest.fail "Partial.to_yojson must return Assoc"
;;

(* The hand-rolled Partial.to_string must round-trip to the same 14 fields/values as the
   Yojson reference path. *)
let test_partial_to_string_roundtrips () =
  let partial : P.Partial.t =
    { type_ = "partial"
    ; oldest_frame_seq = 1
    ; newest_frame_seq = 50
    ; frames = 50
    ; rms = 2425.5023191083533
    ; zero_crossings = 7
    ; checksum = 1745339397
    ; samples = 64000
    ; transcript = "now"
    ; audio_bytes = 32000
    ; cpu_passes = 4
    ; model_delay_ms = 75
    ; flush_lateness_ms = 35.0
    ; inflight_model_jobs = 0
    }
  in
  let direct = P.Partial.to_string partial in
  match Yojson.Safe.from_string direct with
  | exception e -> Alcotest.failf "to_string not valid JSON: %s" (Exn.to_string e)
  | `Assoc fields ->
    let ref_fields =
      match P.Partial.to_yojson partial with
      | `Assoc f -> f
      | _ -> []
    in
    let norm l = List.sort l ~compare:(fun (a, _) (b, _) -> String.compare a b) in
    let keys l = List.map l ~f:fst |> List.sort ~compare:String.compare in
    Alcotest.(check (list string))
      "to_string keys == to_yojson keys"
      (keys ref_fields)
      (keys fields);
    let find l k = List.Assoc.find_exn l k ~equal:String.equal in
    List.iter (norm ref_fields) ~f:(fun (k, v) ->
      let got = find fields k in
      let same =
        match v, got with
        | `Float a, `Float b -> Float.( <= ) (Float.abs (a -. b)) 1e-6
        | `Float a, `Int b | `Int b, `Float a ->
          Float.( <= ) (Float.abs (a -. Float.of_int b)) 1e-6
        | a, b -> Poly.equal a b
      in
      if not same
      then
        Alcotest.failf
          "field %s mismatch: ref=%s got=%s"
          k
          (Yojson.Safe.to_string v)
          (Yojson.Safe.to_string got))
  | _ -> Alcotest.fail "to_string must be a JSON object"
;;

let test_runtime_version_assertion () =
  Alcotest.(check string)
    "expected_ocaml_version"
    "5.2.0+ox"
    Stt_ocaml_oxcaml.Runtime.expected_ocaml_version
;;

module D = Stt_ocaml_oxcaml.Diagnostics

let fake_getenv pairs name = List.Assoc.find pairs name ~equal:String.equal

let test_diagnostics_config_parses_env () =
  let disabled = D.Config.of_getenv (fake_getenv []) in
  Alcotest.(check bool) "disabled by default" false disabled.enabled;
  Alcotest.(check int) "default interval" 5000 disabled.interval_ms;
  Alcotest.(check int) "default sample every" 100 disabled.sample_every;
  Alcotest.(check bool) "trace disabled by default" false disabled.trace_enabled;
  Alcotest.(check (option string)) "trace file absent by default" None disabled.trace_file;
  let enabled =
    D.Config.of_getenv
      (fake_getenv
         [ "OXCAML_DIAG", "1"
         ; "OXCAML_DIAG_INTERVAL_MS", "1234"
         ; "OXCAML_DIAG_SAMPLE_EVERY", "7"
         ; "OXCAML_TRACE", "1"
         ; "OXCAML_TRACE_FILE", "/tmp/oxcaml-trace.json"
         ; "OXCAML_TRACE_SAMPLE_EVERY", "3"
         ; "OXCAML_TRACE_FLUSH_INTERVAL_MS", "4321"
         ; "OXCAML_TRACE_FRAME_SAMPLE_EVERY", "17"
         ])
  in
  Alcotest.(check bool) "enabled" true enabled.enabled;
  Alcotest.(check int) "interval" 1234 enabled.interval_ms;
  Alcotest.(check int) "sample every" 7 enabled.sample_every;
  Alcotest.(check bool) "trace enabled" true enabled.trace_enabled;
  Alcotest.(check (option string))
    "trace file"
    (Some "/tmp/oxcaml-trace.json")
    enabled.trace_file;
  Alcotest.(check int) "trace sample every" 3 enabled.trace_sample_every;
  Alcotest.(check int) "trace flush interval" 4321 enabled.trace_flush_interval_ms;
  Alcotest.(check int) "trace frame sample every" 17 enabled.trace_frame_sample_every
;;

let test_diagnostics_snapshot_json_has_counters () =
  let config =
    D.Config.of_getenv
      (fake_getenv
         [ "OXCAML_DIAG", "1"
         ; "OXCAML_DIAG_INTERVAL_MS", "100"
         ; "OXCAML_DIAG_SAMPLE_EVERY", "1"
         ])
  in
  let diag = D.create config in
  let session_id = D.record_session_opened diag in
  D.record_session_closed diag ~session_id;
  D.record_binary_frame diag ~session_id ~seq:1 ~bytes:640;
  D.record_flush_tick diag;
  D.record_flush_skip_inflight diag;
  D.record_flush_skip_empty diag;
  D.record_batch diag ~frames:50 ~bytes:32000;
  let json = Yojson.Safe.from_string (D.snapshot_json_for_test diag) in
  let assoc name = function
    | `Assoc fields -> fields
    | other ->
      Alcotest.failf "%s must be object, got %s" name (Yojson.Safe.to_string other)
  in
  let field name fields = List.Assoc.find_exn fields name ~equal:String.equal in
  let int_field name fields =
    match field name fields with
    | `Int n -> n
    | other -> Alcotest.failf "%s must be int, got %s" name (Yojson.Safe.to_string other)
  in
  let root = assoc "root" json in
  Alcotest.(check string)
    "type"
    "oxcaml_diag"
    (Yojson.Safe.Util.to_string (field "type" root));
  let counters = field "counters" root |> assoc "counters" in
  Alcotest.(check int) "sessions_opened" 1 (int_field "sessions_opened" counters);
  Alcotest.(check int) "sessions_closed" 1 (int_field "sessions_closed" counters);
  Alcotest.(check int) "binary_frames" 1 (int_field "binary_frames" counters);
  Alcotest.(check int) "binary_bytes" 640 (int_field "binary_bytes" counters);
  Alcotest.(check int) "flush_ticks" 1 (int_field "flush_ticks" counters);
  Alcotest.(check int) "flush_skip_inflight" 1 (int_field "flush_skip_inflight" counters);
  Alcotest.(check int) "flush_skip_empty" 1 (int_field "flush_skip_empty" counters);
  Alcotest.(check int) "batches" 1 (int_field "batches" counters);
  Alcotest.(check int) "batch_frames" 50 (int_field "batch_frames" counters);
  Alcotest.(check int) "batch_bytes" 32000 (int_field "batch_bytes" counters);
  let timings = field "timings" root |> assoc "timings" in
  ignore (field "inference" timings : Yojson.Safe.t);
  ignore (field "serialization" timings : Yojson.Safe.t);
  ignore (field "outbound_write" timings : Yojson.Safe.t);
  ignore (field "response_parse" timings : Yojson.Safe.t);
  ignore (field "gc" root : Yojson.Safe.t)
;;

let test_diagnostics_trace_snapshot_records_sampled_span () =
  let config =
    D.Config.of_getenv
      (fake_getenv
         [ "OXCAML_TRACE", "1"
         ; "OXCAML_TRACE_FILE", "/tmp/oxcaml-trace.json"
         ; "OXCAML_TRACE_SAMPLE_EVERY", "1"
         ])
  in
  let diag = D.create config in
  let sample = D.start_timing diag D.Inference in
  D.finish_timing
    diag
    D.Inference
    ~trace_tid:7
    ~trace_args:[ D.Int_arg ("frames", 50); D.Int_arg ("bytes", 32000) ]
    sample;
  D.record_trace_instant
    diag
    ~name:"flush_skip_empty"
    ~trace_tid:7
    ~trace_args:[ D.Int_arg ("session_id", 7) ];
  D.record_trace_counter
    diag
    ~name:"buffer_frames"
    ~trace_tid:7
    ~trace_args:[ D.Int_arg ("frames", 0) ];
  match D.trace_json_for_test diag with
  | None -> Alcotest.fail "trace JSON must be available when tracing is enabled"
  | Some trace ->
    let json = Yojson.Safe.from_string trace in
    let root =
      match json with
      | `Assoc fields -> fields
      | other ->
        Alcotest.failf "trace root must be object, got %s" (Yojson.Safe.to_string other)
    in
    let events =
      match List.Assoc.find_exn root "traceEvents" ~equal:String.equal with
      | `List events -> events
      | other ->
        Alcotest.failf "traceEvents must be list, got %s" (Yojson.Safe.to_string other)
    in
    Alcotest.(check int) "three trace events" 3 (List.length events);
    let assoc_event event =
      match event with
      | `Assoc fields -> fields
      | other ->
        Alcotest.failf "event must be object, got %s" (Yojson.Safe.to_string other)
    in
    let event = List.hd_exn events |> assoc_event in
    Alcotest.(check string)
      "event name"
      "inference"
      (Yojson.Safe.Util.to_string (List.Assoc.find_exn event "name" ~equal:String.equal));
    Alcotest.(check string)
      "event phase"
      "X"
      (Yojson.Safe.Util.to_string (List.Assoc.find_exn event "ph" ~equal:String.equal));
    Alcotest.(check int)
      "duration event tid"
      7
      (Yojson.Safe.Util.to_int (List.Assoc.find_exn event "tid" ~equal:String.equal));
    let args =
      match List.Assoc.find_exn event "args" ~equal:String.equal with
      | `Assoc fields -> fields
      | other ->
        Alcotest.failf "args must be object, got %s" (Yojson.Safe.to_string other)
    in
    Alcotest.(check int)
      "frames arg"
      50
      (Yojson.Safe.Util.to_int (List.Assoc.find_exn args "frames" ~equal:String.equal));
    Alcotest.(check int)
      "bytes arg"
      32000
      (Yojson.Safe.Util.to_int (List.Assoc.find_exn args "bytes" ~equal:String.equal));
    let instant = List.nth_exn events 1 |> assoc_event in
    Alcotest.(check string)
      "instant name"
      "flush_skip_empty"
      (Yojson.Safe.Util.to_string
         (List.Assoc.find_exn instant "name" ~equal:String.equal));
    Alcotest.(check string)
      "instant phase"
      "i"
      (Yojson.Safe.Util.to_string (List.Assoc.find_exn instant "ph" ~equal:String.equal));
    let counter = List.nth_exn events 2 |> assoc_event in
    Alcotest.(check string)
      "counter name"
      "buffer_frames"
      (Yojson.Safe.Util.to_string
         (List.Assoc.find_exn counter "name" ~equal:String.equal));
    Alcotest.(check string)
      "counter phase"
      "C"
      (Yojson.Safe.Util.to_string (List.Assoc.find_exn counter "ph" ~equal:String.equal))
;;

let test_inflight_capability_token_roundtrip () =
  let cap = Stt_ocaml_oxcaml.Inflight_capability.create_for_session () in
  let token = Stt_ocaml_oxcaml.Inflight_capability.consume cap in
  let _cap' = Stt_ocaml_oxcaml.Inflight_capability.of_token token in
  ()
;;

module WF = Stt_ocaml_oxcaml.Websocket_frame
module WH = Stt_ocaml_oxcaml.Websocket_handshake

(* RFC 6455 §1.3 worked example: this exact key must produce this exact accept value. *)
let test_accept_key_rfc_vector () =
  Alcotest.(check string)
    "rfc 6455 accept vector"
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (WH.accept_key ~key:"dGhlIHNhbXBsZSBub25jZQ==")
;;

let test_close_code_encoding () =
  let f = WF.close ~code:1002 () in
  (match f.opcode with
   | WF.Close -> ()
   | _ -> Alcotest.fail "close frame opcode must be Close");
  Alcotest.(check bool) "fin" true f.fin;
  Alcotest.(check int) "close payload is 2 bytes" 2 (String.length f.payload);
  let hi = Char.to_int f.payload.[0] in
  let lo = Char.to_int f.payload.[1] in
  Alcotest.(check int) "big-endian close code" 1002 ((hi * 256) + lo)
;;

let test_frame_constructors () =
  let t = WF.text "hi" in
  (match t.opcode with
   | WF.Text -> ()
   | _ -> Alcotest.fail "text opcode");
  Alcotest.(check string) "text payload" "hi" t.payload;
  let b = WF.binary "\000\001" in
  match b.opcode with
  | WF.Binary -> Alcotest.(check string) "binary payload" "\000\001" b.payload
  | _ -> Alcotest.fail "binary opcode"
;;

let block = Async.Thread_safe.block_on_async_exn

let reader_of_string s =
  let open Async in
  let pr, pw = Pipe.create () in
  Pipe.write_without_pushback pw s;
  Pipe.close pw;
  Reader.of_pipe (Core.Info.of_string "ws-test") pr
;;

(* Minimal RFC 6455 client frame: FIN=1, given opcode, masked, 7-bit length, 4-byte mask,
   masked payload. [masked] lets a test deliberately send an (illegal) unmasked frame. *)
let client_frame ?(masked = true) ?(fin = true) ~opcode ~payload () =
  let len = String.length payload in
  let b = Buffer.create (6 + len) in
  Buffer.add_char b (Char.of_int_exn ((if fin then 0x80 else 0) lor (opcode land 0x0f)));
  Buffer.add_char b (Char.of_int_exn ((if masked then 0x80 else 0) lor len));
  let mask = "\x12\x34\x56\x78" in
  if masked
  then (
    Buffer.add_string b mask;
    String.iteri payload ~f:(fun i c ->
      Buffer.add_char b (Char.of_int_exn (Char.to_int c lxor Char.to_int mask.[i land 3]))))
  else Buffer.add_string b payload;
  Buffer.contents b
;;

let test_masked_text_roundtrips () =
  block (fun () ->
    let open Async in
    let%bind reader = reader_of_string (client_frame ~opcode:1 ~payload:"hello" ()) in
    match%map WF.read reader with
    | `Ok frame ->
      (match frame.opcode with
       | WF.Text -> ()
       | _ -> Alcotest.fail "expected Text");
      Alcotest.(check string) "unmasked payload" "hello" frame.payload
    | `Eof -> Alcotest.fail "unexpected Eof"
    | `Error e -> Alcotest.failf "unexpected Error %s" e)
;;

let test_unmasked_client_rejected () =
  block (fun () ->
    let open Async in
    let%bind reader =
      reader_of_string (client_frame ~masked:false ~opcode:1 ~payload:"x" ())
    in
    match%map WF.read reader with
    | `Error _ -> ()
    | `Ok _ -> Alcotest.fail "RFC 6455 §5.1: unmasked client frame must be rejected"
    | `Eof -> Alcotest.fail "unexpected Eof")
;;

let test_fragmented_control_frame_rejected () =
  block (fun () ->
    let open Async in
    (* opcode 9 = Ping (control); RFC 6455 §5.5 forbids a fragmented (FIN=0) control
       frame. *)
    let%bind reader =
      reader_of_string (client_frame ~fin:false ~opcode:9 ~payload:"ab" ())
    in
    match%map WF.read reader with
    | `Error _ -> ()
    | `Ok _ -> Alcotest.fail "fragmented control frame must be rejected"
    | `Eof -> Alcotest.fail "unexpected Eof")
;;

(* Regression guard for the timeout/cancellation fix: a silent inference server that never
   responds must see EXACTLY ONE inbound connection for one [Inference.send] — the
   orphaned (timed-out) request must not redial. Pre-fix this produced two requests. *)
let test_silent_inference_times_out_without_redial () =
  block (fun () ->
    let open Async in
    let connections = ref 0 in
    let%bind server =
      Tcp.Server.create
        ~on_handler_error:`Ignore
        (Tcp.Where_to_listen.of_port 0)
        (fun _addr _reader _writer ->
           incr connections;
           Deferred.never ())
    in
    let port = Tcp.Server.listening_on server in
    let config : Stt_ocaml_oxcaml.Config.t =
      { port = 0
      ; inference_host = "127.0.0.1"
      ; inference_port = port
      ; inference_http_clients = 1
      ; worker_threads = 1
      ; flush_interval_ms = 1000
      ; flush_phase_jitter_ms = 0
      ; cpu_passes = 4
      ; model_delay_ms = 75
      }
    in
    let inference = Stt_ocaml_oxcaml.Inference.create config in
    let conn = Stt_ocaml_oxcaml.Inference.create_conn () in
    let capability = Stt_ocaml_oxcaml.Inflight_capability.create_for_session () in
    let%bind outcome =
      Stt_ocaml_oxcaml.Inference.send
        inference
        ~conn
        ~capability
        ~body:[ String.make 640 '\000' ]
        ~body_len:640
    in
    (match outcome.result with
     | Error e ->
       (match e.kind with
        | Stt_ocaml_oxcaml.Protocol.Error_kind.Timeout -> ()
        | _ -> Alcotest.failf "expected Timeout, got kind=%s" e.message)
     | Ok _ -> Alcotest.fail "silent server must not yield Ok");
    Alcotest.(check int) "exactly one request before timeout" 1 !connections;
    (* Wait well past the 2 s deadline: a buggy orphan would redial here. *)
    let%bind () = Clock_ns.after (Time_ns.Span.of_sec 1.5) in
    Alcotest.(check int) "no redial after timeout" 1 !connections;
    let%bind () = Stt_ocaml_oxcaml.Inference.close_conn conn in
    Tcp.Server.close server)
;;

let () =
  let open Alcotest in
  run
    "stt_ocaml_oxcaml"
    [ ( "protocol"
      , [ test_case
            "Start_message: accepts canonical"
            `Quick
            test_start_message_accepts_canonical
        ; test_case
            "Start_message: rejects unknown field"
            `Quick
            test_start_message_rejects_unknown_field
        ; test_case
            "Start_message: rejects missing type"
            `Quick
            test_start_message_rejects_missing_type
        ; test_case
            "Infer_response: decodes canonical"
            `Quick
            test_infer_response_decodes_canonical
        ; test_case
            "Infer_response: rejects unknown field"
            `Quick
            test_infer_response_rejects_unknown_field
        ; test_case
            "Partial: serializes exact 14-field set"
            `Quick
            test_partial_serializes_exact_field_set
        ; test_case
            "Partial: to_string round-trips to_yojson"
            `Quick
            test_partial_to_string_roundtrips
        ] )
    ; ( "runtime"
      , [ test_case
            "expected OxCaml version constant"
            `Quick
            test_runtime_version_assertion
        ] )
    ; ( "diagnostics"
      , [ test_case "config parses env" `Quick test_diagnostics_config_parses_env
        ; test_case
            "snapshot JSON has counters"
            `Quick
            test_diagnostics_snapshot_json_has_counters
        ; test_case
            "trace snapshot records sampled span"
            `Quick
            test_diagnostics_trace_snapshot_records_sampled_span
        ] )
    ; ( "inflight_capability"
      , [ test_case "token round-trip" `Quick test_inflight_capability_token_roundtrip ] )
    ; ( "websocket_handshake"
      , [ test_case "RFC 6455 accept vector" `Quick test_accept_key_rfc_vector ] )
    ; ( "websocket_frame"
      , [ test_case "close code encoding" `Quick test_close_code_encoding
        ; test_case "constructors" `Quick test_frame_constructors
        ; test_case "masked text round-trips" `Quick test_masked_text_roundtrips
        ; test_case "unmasked client rejected" `Quick test_unmasked_client_rejected
        ; test_case
            "fragmented control frame rejected"
            `Quick
            test_fragmented_control_frame_rejected
        ] )
    ; ( "inference_timeout"
      , [ test_case
            "silent server times out without redial"
            `Slow
            test_silent_inference_times_out_without_redial
        ] )
    ]
;;
