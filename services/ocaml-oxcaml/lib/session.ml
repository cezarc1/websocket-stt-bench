open! Core
open! Async

type close_action =
  | Continue
  | Close of
      { code : int
      ; reason : string
      }

(* [payload] is the [Ws_frame] string verbatim — no Bigstring conversion on the 50
   fps/session receive path. At flush the frame strings are written straight to the
   inference socket (no concat buffer). *)
type frame =
  { seq : int
  ; payload : string
  ; received_at : Time_ns.t
  }

type t =
  { config : Config.t
  ; inference : Inference.t
  ; inf_conn : Inference.conn
  ; outbound : string Pipe.Writer.t
  ; buffer : frame Queue.t
  ; mutable seq : int
  ; cap_mvar : Inflight_capability.t Mvar.Read_write.t
  }

let create ~config ~inference ~outbound =
  let cap_mvar = Mvar.create () in
  Mvar.set cap_mvar (Inflight_capability.create_for_session ());
  { config
  ; inference
  ; inf_conn = Inference.create_conn ()
  ; outbound
  ; buffer = Queue.create ()
  ; seq = 0
  ; cap_mvar
  }
;;

let on_binary (t : t) (payload : string) =
  if String.length payload <> Protocol.frame_bytes
  then
    Close { code = 1003; reason = sprintf "frame must be %d bytes" Protocol.frame_bytes }
  else (
    t.seq <- t.seq + 1;
    Queue.enqueue t.buffer { seq = t.seq; payload; received_at = Time_ns.now () };
    Continue)
;;

let drain_buffer t =
  let snapshot = Queue.to_list t.buffer in
  Queue.clear t.buffer;
  snapshot
;;

let build_partial
  ~(infer : Protocol.Infer_response.t)
  ~oldest_seq
  ~newest_seq
  ~frame_count
  ~flush_lateness_ms
  ~cpu_passes
  ~model_delay_ms
  : Protocol.Partial.t
  =
  { type_ = "partial"
  ; oldest_frame_seq = oldest_seq
  ; newest_frame_seq = newest_seq
  ; frames = frame_count
  ; rms = infer.rms
  ; zero_crossings = infer.zero_crossings
  ; checksum = infer.checksum
  ; samples = infer.samples
  ; transcript = infer.transcript
  ; audio_bytes = infer.audio_bytes
  ; cpu_passes
  ; model_delay_ms
  ; flush_lateness_ms
  ; inflight_model_jobs = 0
  }
;;

let build_error
  t
  ~(err : Inference.error)
  ~oldest_seq
  ~newest_seq
  ~frame_count
  ~audio_bytes
  ~oldest_age_ms
  ~newest_age_ms
  ~flush_lateness_ms
  ~inference_elapsed_ms
  : Protocol.Error.t
  =
  (* Mirrors Rust/Go: parse errors and 4xx (except 429) are deterministic client/config
     bugs — not worth retrying. timeout, connection_reset, 429, and 5xx are transient. *)
  let retryable =
    match err.kind with
    | "parse_error" -> false
    | _ ->
      (match err.status with
       | Some s -> s = 429 || s >= 500
       | None -> true)
  in
  { type_ = "error"
  ; stage = err.stage
  ; kind = err.kind
  ; message = err.message
  ; oldest_frame_seq = oldest_seq
  ; newest_frame_seq = newest_seq
  ; frames = frame_count
  ; audio_bytes
  ; oldest_age_ms
  ; newest_age_ms
  ; flush_lateness_ms
  ; inference_elapsed_ms = Some inference_elapsed_ms
  ; inflight_gateway_batches = 1
  ; gateway_buffer_frames = Queue.length t.buffer
  ; inference_status = err.status
  ; retryable
  }
;;

let jittered_start t =
  let jitter_ms =
    if t.config.flush_phase_jitter_ms <= 0
    then 0.0
    else (
      let r = Random.float 1.0 in
      Float.of_int t.config.flush_phase_jitter_ms *. r)
  in
  Time_ns.add
    (Time_ns.now ())
    (Time_ns.Span.of_ms (Float.of_int t.config.flush_interval_ms +. jitter_ms))
;;

let ms_since (t_ns : Time_ns.t) = Time_ns.diff (Time_ns.now ()) t_ns |> Time_ns.Span.to_ms

let perform_flush t ~expected_at =
  let now = Time_ns.now () in
  let flush_lateness_ms =
    Float.max 0.0 (Time_ns.diff now expected_at |> Time_ns.Span.to_ms)
  in
  match Mvar.take_now t.cap_mvar with
  | None -> return ()
  | Some capability ->
    let frames = drain_buffer t in
    (match frames with
     | [] ->
       Mvar.set t.cap_mvar capability;
       return ()
     | oldest_frame :: _ ->
       let newest_frame = List.last_exn frames in
       let oldest_seq = oldest_frame.seq in
       let newest_seq = newest_frame.seq in
       let frame_count = List.length frames in
       let body = List.map frames ~f:(fun f -> f.payload) in
       let audio_bytes = List.fold body ~init:0 ~f:(fun acc s -> acc + String.length s) in
       let emit s =
         if Pipe.is_closed t.outbound then return () else Pipe.write t.outbound s
       in
       let inference_start = Time_ns.now () in
       Inference.send t.inference ~conn:t.inf_conn ~capability ~body ~body_len:audio_bytes
       >>= fun outcome ->
       let inference_elapsed_ms = ms_since inference_start in
       let%bind () =
         match outcome.result with
         | Ok infer ->
           let partial =
             build_partial
               ~infer
               ~oldest_seq
               ~newest_seq
               ~frame_count
               ~flush_lateness_ms
               ~cpu_passes:t.config.cpu_passes
               ~model_delay_ms:t.config.model_delay_ms
           in
           emit (Protocol.Partial.to_string partial)
         | Error err ->
           Log.Global.error
             "inference error stage=%s kind=%s status=%s msg=%s"
             err.stage
             err.kind
             (Option.value_map err.status ~default:"-" ~f:Int.to_string)
             err.message;
           let envelope =
             build_error
               t
               ~err
               ~oldest_seq
               ~newest_seq
               ~frame_count
               ~audio_bytes
               ~oldest_age_ms:(ms_since oldest_frame.received_at)
               ~newest_age_ms:(ms_since newest_frame.received_at)
               ~flush_lateness_ms
               ~inference_elapsed_ms
           in
           emit (Protocol.Error.to_string envelope)
       in
       Mvar.set t.cap_mvar (Inflight_capability.of_token outcome.token);
       return ())
;;

let run_flush_loop t =
  let start = jittered_start t in
  let step = Time_ns.Span.of_ms (Float.of_int t.config.flush_interval_ms) in
  let rec loop expected_at =
    if Pipe.is_closed t.outbound
    then Inference.close_conn t.inf_conn
    else (
      let now = Time_ns.now () in
      let wait =
        let delta = Time_ns.diff expected_at now in
        if Time_ns.Span.( < ) delta Time_ns.Span.zero then Time_ns.Span.zero else delta
      in
      let%bind () = Clock_ns.after wait in
      let%bind () = perform_flush t ~expected_at in
      loop (Time_ns.add expected_at step))
  in
  loop start
;;
