open! Core
open! Async

type close_action =
  | Continue
  | Close of
      { code : int
      ; reason : string
      }

(* [payload] is the [Websocket_frame] string verbatim — no Bigstring conversion on the 50
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

type drained =
  { body : string list (* frame payloads, oldest-first *)
  ; body_len : int
  ; frame_count : int
  ; oldest_seq : int
  ; newest_seq : int
  ; oldest_received_at : Time_ns.t
  ; newest_received_at : Time_ns.t
  }

(* One pass over the buffer instead of to_list + map + fold + last_exn + length: this is
   the measured CPU-bound hot path (~2k flushes/s on the single Async domain). Frames
   enqueue in receive order, so the first folded frame is oldest and the last is newest. *)
let drain t : drained option =
  match Queue.peek t.buffer with
  | None -> None
  | Some first ->
    let acc =
      Queue.fold
        t.buffer
        ~init:
          { body = []
          ; body_len = 0
          ; frame_count = 0
          ; oldest_seq = first.seq
          ; newest_seq = first.seq
          ; oldest_received_at = first.received_at
          ; newest_received_at = first.received_at
          }
        ~f:(fun acc f ->
          { acc with
            body = f.payload :: acc.body
          ; body_len = acc.body_len + String.length f.payload
          ; frame_count = acc.frame_count + 1
          ; newest_seq = f.seq
          ; newest_received_at = f.received_at
          })
    in
    Queue.clear t.buffer;
    Some { acc with body = List.rev acc.body }
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
  (* Mirrors Rust/Go: a parse error is a deterministic client/config bug — never retry.
     timeout / connection_reset / 429 are transient. [Inference] lumps every non-200,
     non-429 status into [Http_5xx], so the actual status is consulted there to keep a
     deterministic 4xx (≠429) non-retryable, exactly as before this was a sum type. *)
  let retryable =
    match err.kind with
    | Protocol.Error_kind.Parse_error -> false
    | Timeout | Connection_reset | Http_429 -> true
    | Http_5xx ->
      (match err.status with
       | Some s -> s >= 500
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
    (match drain t with
     | None ->
       Mvar.set t.cap_mvar capability;
       return ()
     | Some d ->
       let emit s =
         if Pipe.is_closed t.outbound then return () else Pipe.write t.outbound s
       in
       let inference_start = Time_ns.now () in
       Inference.send
         t.inference
         ~conn:t.inf_conn
         ~capability
         ~body:d.body
         ~body_len:d.body_len
       >>= fun outcome ->
       let inference_elapsed_ms = ms_since inference_start in
       let%bind () =
         match outcome.result with
         | Ok infer ->
           let partial =
             build_partial
               ~infer
               ~oldest_seq:d.oldest_seq
               ~newest_seq:d.newest_seq
               ~frame_count:d.frame_count
               ~flush_lateness_ms
               ~cpu_passes:t.config.cpu_passes
               ~model_delay_ms:t.config.model_delay_ms
           in
           emit (Protocol.Partial.to_string partial)
         | Error err ->
           Log.Global.error
             "inference error stage=%s kind=%s status=%s msg=%s"
             (Protocol.Error_stage.to_wire err.stage)
             (Protocol.Error_kind.to_wire err.kind)
             (Option.value_map err.status ~default:"-" ~f:Int.to_string)
             err.message;
           let envelope =
             build_error
               t
               ~err
               ~oldest_seq:d.oldest_seq
               ~newest_seq:d.newest_seq
               ~frame_count:d.frame_count
               ~audio_bytes:d.body_len
               ~oldest_age_ms:(ms_since d.oldest_received_at)
               ~newest_age_ms:(ms_since d.newest_received_at)
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
