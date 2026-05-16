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

  let to_string t = Yojson.Safe.to_string (to_yojson t)
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
