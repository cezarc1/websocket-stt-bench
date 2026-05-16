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

let test_runtime_version_assertion () =
  Alcotest.(check string)
    "expected_ocaml_version"
    "5.2.0+ox"
    Stt_ocaml_oxcaml.Runtime.expected_ocaml_version
;;

let test_inflight_capability_token_roundtrip () =
  let cap = Stt_ocaml_oxcaml.Inflight_capability.create_for_session () in
  let token = Stt_ocaml_oxcaml.Inflight_capability.consume cap in
  let _cap' = Stt_ocaml_oxcaml.Inflight_capability.of_token token in
  ()
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
        ] )
    ; ( "runtime"
      , [ test_case
            "expected OxCaml version constant"
            `Quick
            test_runtime_version_assertion
        ] )
    ; ( "inflight_capability"
      , [ test_case "token round-trip" `Quick test_inflight_capability_token_roundtrip ] )
    ]
;;
