open! Core

let frame_bytes = 640

module Start_message = struct
  type t = { type_ : string }

  let of_yojson (json : Yojson.Safe.t) : (t, string) Result.t =
    match json with
    | `Assoc fields ->
      (match List.Assoc.find fields ~equal:String.equal "type" with
       | Some (`String value) when List.length fields = 1 -> Ok { type_ = value }
       | Some _ -> Error "Start_message: rejected unknown fields"
       | None -> Error "Start_message: missing required \"type\" field")
    | _ -> Error "Start_message: expected JSON object"
  ;;
end

module Infer_response = struct
  type t =
    { rms : float
    ; zero_crossings : int
    ; checksum : int
    ; samples : int
    ; transcript : string
    ; audio_bytes : int
    }

  (* Fields the inference server returns. Anything else -> error. *)
  let known_keys =
    String.Set.of_list
      [ "rms"; "zero_crossings"; "checksum"; "samples"; "transcript"; "audio_bytes" ]
  ;;

  let read_float = function
    | `Float f -> Ok f
    | `Int i -> Ok (Float.of_int i)
    | _ -> Error "expected number"
  ;;

  let read_int = function
    | `Int i -> Ok i
    | `Intlit s ->
      (match Int.of_string_opt s with
       | Some i -> Ok i
       | None -> Error "Intlit out of range")
    | _ -> Error "expected integer"
  ;;

  let read_string = function
    | `String s -> Ok s
    | _ -> Error "expected string"
  ;;

  let of_yojson (json : Yojson.Safe.t) : (t, string) Result.t =
    match json with
    | `Assoc fields ->
      let unknown =
        List.filter_map fields ~f:(fun (k, _) ->
          if Set.mem known_keys k then None else Some k)
      in
      if not (List.is_empty unknown)
      then
        Error
          (sprintf
             "Infer_response: rejected unknown fields: %s"
             (String.concat ~sep:"," unknown))
      else
        let open Result.Let_syntax in
        let find key reader =
          match List.Assoc.find fields ~equal:String.equal key with
          | Some v -> reader v
          | None -> Error (sprintf "Infer_response: missing %s" key)
        in
        let%bind rms = find "rms" read_float in
        let%bind zero_crossings = find "zero_crossings" read_int in
        let%bind checksum = find "checksum" read_int in
        let%bind samples = find "samples" read_int in
        let%bind transcript = find "transcript" read_string in
        let%bind audio_bytes = find "audio_bytes" read_int in
        Ok { rms; zero_crossings; checksum; samples; transcript; audio_bytes }
    | _ -> Error "Infer_response: expected JSON object"
  ;;
end

module Partial = struct
  type t =
    { type_ : string
    ; oldest_frame_seq : int
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
    ; inflight_model_jobs : int
    }

  (* Kept for the exact-field-set unit test; the runtime hot path uses {!to_string} below,
     which writes directly into a [Buffer] and skips the 14-node Yojson tree + generic
     serializer. At the measured CPU-bound ceiling this is ~2k partials/s on the single
     Async domain, so the per-partial allocation matters. *)
  let to_yojson (t : t) : Yojson.Safe.t =
    `Assoc
      [ "type", `String t.type_
      ; "oldest_frame_seq", `Int t.oldest_frame_seq
      ; "newest_frame_seq", `Int t.newest_frame_seq
      ; "frames", `Int t.frames
      ; "rms", `Float t.rms
      ; "zero_crossings", `Int t.zero_crossings
      ; "checksum", `Int t.checksum
      ; "samples", `Int t.samples
      ; "transcript", `String t.transcript
      ; "audio_bytes", `Int t.audio_bytes
      ; "cpu_passes", `Int t.cpu_passes
      ; "model_delay_ms", `Int t.model_delay_ms
      ; "flush_lateness_ms", `Float t.flush_lateness_ms
      ; "inflight_model_jobs", `Int t.inflight_model_jobs
      ]
  ;;

  (* JSON string escaping for the transcript. The inference stub's vocabulary is plain
     ASCII words, but escape defensively so a future transcript can't produce invalid
     JSON. *)
  let add_json_string buf s =
    Buffer.add_char buf '"';
    String.iter s ~f:(fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.to_int c < 0x20 ->
        Buffer.add_string buf (sprintf "\\u%04x" (Char.to_int c))
      | c -> Buffer.add_char buf c);
    Buffer.add_char buf '"'
  ;;

  (* [%.17g] round-trips an IEEE double losslessly and is a valid JSON number;
     rms/flush_lateness_ms are always finite here. *)
  let add_float buf f = Buffer.add_string buf (sprintf "%.17g" f)
  let add_int buf i = Buffer.add_string buf (Int.to_string i)

  let to_string (t : t) =
    let b = Buffer.create 256 in
    Buffer.add_string b {|{"type":|};
    add_json_string b t.type_;
    Buffer.add_string b {|,"oldest_frame_seq":|};
    add_int b t.oldest_frame_seq;
    Buffer.add_string b {|,"newest_frame_seq":|};
    add_int b t.newest_frame_seq;
    Buffer.add_string b {|,"frames":|};
    add_int b t.frames;
    Buffer.add_string b {|,"rms":|};
    add_float b t.rms;
    Buffer.add_string b {|,"zero_crossings":|};
    add_int b t.zero_crossings;
    Buffer.add_string b {|,"checksum":|};
    add_int b t.checksum;
    Buffer.add_string b {|,"samples":|};
    add_int b t.samples;
    Buffer.add_string b {|,"transcript":|};
    add_json_string b t.transcript;
    Buffer.add_string b {|,"audio_bytes":|};
    add_int b t.audio_bytes;
    Buffer.add_string b {|,"cpu_passes":|};
    add_int b t.cpu_passes;
    Buffer.add_string b {|,"model_delay_ms":|};
    add_int b t.model_delay_ms;
    Buffer.add_string b {|,"flush_lateness_ms":|};
    add_float b t.flush_lateness_ms;
    Buffer.add_string b {|,"inflight_model_jobs":|};
    add_int b t.inflight_model_jobs;
    Buffer.add_char b '}';
    Buffer.contents b
  ;;
end

module Error = struct
  type t =
    { type_ : string
    ; stage : string
    ; kind : string
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

  let float_or_null = function
    | None -> `Null
    | Some f -> `Float f
  ;;

  let int_or_null = function
    | None -> `Null
    | Some i -> `Int i
  ;;

  let to_yojson (t : t) : Yojson.Safe.t =
    `Assoc
      [ "type", `String t.type_
      ; "stage", `String t.stage
      ; "kind", `String t.kind
      ; "message", `String t.message
      ; "oldest_frame_seq", `Int t.oldest_frame_seq
      ; "newest_frame_seq", `Int t.newest_frame_seq
      ; "frames", `Int t.frames
      ; "audio_bytes", `Int t.audio_bytes
      ; "oldest_age_ms", `Float t.oldest_age_ms
      ; "newest_age_ms", `Float t.newest_age_ms
      ; "flush_lateness_ms", `Float t.flush_lateness_ms
      ; "inference_elapsed_ms", float_or_null t.inference_elapsed_ms
      ; "inflight_gateway_batches", `Int t.inflight_gateway_batches
      ; "gateway_buffer_frames", `Int t.gateway_buffer_frames
      ; "inference_status", int_or_null t.inference_status
      ; "retryable", `Bool t.retryable
      ]
  ;;

  let to_string t = Yojson.Safe.to_string (to_yojson t)
end
