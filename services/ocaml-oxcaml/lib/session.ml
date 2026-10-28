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
   inference socket (no concat buffer).

   A session normally accumulates about 50 frames between flush ticks, so a small mutable
   array avoids one record + Queue node allocation per frame. It still grows if an
   in-flight inference makes the next tick skip and the buffer crosses the normal window. *)
type frame_buffer =
  { mutable payloads : string array
  ; mutable count : int
  ; mutable body_len : int
  ; mutable oldest_seq : int
  ; mutable newest_seq : int
  ; mutable oldest_received_at : Time_ns.t
  ; mutable newest_received_at : Time_ns.t
  }

let create_buffer () =
  { payloads = Array.create ~len:64 ""
  ; count = 0
  ; body_len = 0
  ; oldest_seq = 0
  ; newest_seq = 0
  ; oldest_received_at = Time_ns.epoch
  ; newest_received_at = Time_ns.epoch
  }
;;

let buffer_length t = t.count

let buffer_ensure_capacity t =
  if t.count = Array.length t.payloads
  then (
    let next = Array.create ~len:(Int.max 1 (Array.length t.payloads * 2)) "" in
    Array.blit ~src:t.payloads ~src_pos:0 ~dst:next ~dst_pos:0 ~len:t.count;
    t.payloads <- next)
;;

let buffer_push t ~seq ~payload ~received_at =
  buffer_ensure_capacity t;
  if t.count = 0
  then (
    t.oldest_seq <- seq;
    t.oldest_received_at <- received_at);
  t.payloads.(t.count) <- payload;
  t.count <- t.count + 1;
  t.body_len <- t.body_len + String.length payload;
  t.newest_seq <- seq;
  t.newest_received_at <- received_at
;;

let buffer_reset t =
  t.count <- 0;
  t.body_len <- 0;
  t.oldest_seq <- 0;
  t.newest_seq <- 0;
  t.oldest_received_at <- Time_ns.epoch;
  t.newest_received_at <- Time_ns.epoch
;;

type t =
  { config : Config.t
  ; inference : Inference.t
  ; diagnostics : Diagnostics.t
  ; session_id : int
  ; inf_conn : Inference.conn
  ; outbound : string Pipe.Writer.t
  ; buffer : frame_buffer
  ; mutable seq : int
  ; cap_mvar : Inflight_capability.t Mvar.Read_write.t
  }

let create ~config ~inference ~diagnostics ~session_id ~outbound =
  let cap_mvar = Mvar.create () in
  Mvar.set cap_mvar (Inflight_capability.create_for_session ());
  { config
  ; inference
  ; diagnostics
  ; session_id
  ; inf_conn = Inference.create_conn ()
  ; outbound
  ; buffer = create_buffer ()
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
    Diagnostics.record_binary_frame
      t.diagnostics
      ~session_id:t.session_id
      ~seq:t.seq
      ~bytes:(String.length payload);
    buffer_push t.buffer ~seq:t.seq ~payload ~received_at:(Time_ns.now ());
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

(* Emit the oldest-first list expected by [Inference.send]. Frames are already stored in
   receive order, so walking the array backwards and consing once per frame avoids a
   separate list reverse. *)
let drain t : drained option =
  let b = t.buffer in
  if b.count = 0
  then None
  else (
    let body = ref [] in
    for i = b.count - 1 downto 0 do
      let payload = b.payloads.(i) in
      body := payload :: !body;
      b.payloads.(i) <- ""
    done;
    let drained =
      { body = !body
      ; body_len = b.body_len
      ; frame_count = b.count
      ; oldest_seq = b.oldest_seq
      ; newest_seq = b.newest_seq
      ; oldest_received_at = b.oldest_received_at
      ; newest_received_at = b.newest_received_at
      }
    in
    buffer_reset b;
    Some drained)
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
  ; gateway_buffer_frames = buffer_length t.buffer
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

let serialize_partial t partial =
  let timing = Diagnostics.start_timing t.diagnostics Diagnostics.Serialization in
  let payload = Protocol.Partial.to_string partial in
  Diagnostics.finish_timing
    t.diagnostics
    Diagnostics.Serialization
    ~trace_tid:t.session_id
    ~trace_args:[ Diagnostics.Int_arg ("bytes", String.length payload) ]
    timing;
  payload
;;

let serialize_error t envelope =
  let timing = Diagnostics.start_timing t.diagnostics Diagnostics.Serialization in
  let payload = Protocol.Error.to_string envelope in
  Diagnostics.finish_timing
    t.diagnostics
    Diagnostics.Serialization
    ~trace_tid:t.session_id
    ~trace_args:[ Diagnostics.Int_arg ("bytes", String.length payload) ]
    timing;
  payload
;;

let emit t s =
  if Pipe.is_closed t.outbound
  then return ()
  else (
    let timing = Diagnostics.start_timing t.diagnostics Diagnostics.Outbound_write in
    let%map () = Pipe.write t.outbound s in
    Diagnostics.finish_timing
      t.diagnostics
      Diagnostics.Outbound_write
      ~trace_tid:t.session_id
      ~trace_args:[ Diagnostics.Int_arg ("bytes", String.length s) ]
      timing)
;;

let perform_flush t ~expected_at =
  Diagnostics.record_flush_tick t.diagnostics;
  let flush_timing = Diagnostics.start_timing t.diagnostics Diagnostics.Flush_cycle in
  let now = Time_ns.now () in
  let flush_lateness_ms =
    Float.max 0.0 (Time_ns.diff now expected_at |> Time_ns.Span.to_ms)
  in
  let buffer_frames_before = buffer_length t.buffer in
  let flush_args ~status extra =
    [ Diagnostics.Int_arg ("session_id", t.session_id)
    ; Diagnostics.String_arg ("status", status)
    ; Diagnostics.Int_arg ("buffer_frames_before", buffer_frames_before)
    ; Diagnostics.Float_arg ("flush_lateness_ms", flush_lateness_ms)
    ]
    @ extra
  in
  let finish_flush ~status extra =
    Diagnostics.finish_timing
      t.diagnostics
      Diagnostics.Flush_cycle
      ~trace_tid:t.session_id
      ~trace_args:(flush_args ~status extra)
      flush_timing
  in
  Diagnostics.record_trace_instant
    t.diagnostics
    ~name:"flush_tick"
    ~trace_tid:t.session_id
    ~trace_args:(flush_args ~status:"tick" []);
  Diagnostics.record_trace_counter
    t.diagnostics
    ~name:"buffer_frames"
    ~trace_tid:t.session_id
    ~trace_args:
      [ Diagnostics.Int_arg ("session_id", t.session_id)
      ; Diagnostics.Int_arg ("frames", buffer_frames_before)
      ];
  Diagnostics.record_trace_counter
    t.diagnostics
    ~name:"flush_lateness_ms"
    ~trace_tid:t.session_id
    ~trace_args:
      [ Diagnostics.Int_arg ("session_id", t.session_id)
      ; Diagnostics.Float_arg ("ms", flush_lateness_ms)
      ];
  match Mvar.take_now t.cap_mvar with
  | None ->
    Diagnostics.record_flush_skip_inflight t.diagnostics;
    Diagnostics.record_trace_instant
      t.diagnostics
      ~name:"flush_skip_inflight"
      ~trace_tid:t.session_id
      ~trace_args:(flush_args ~status:"skip_inflight" []);
    finish_flush ~status:"skip_inflight" [];
    return ()
  | Some capability ->
    let drain_timing = Diagnostics.start_timing t.diagnostics Diagnostics.Drain in
    (match drain t with
     | None ->
       Diagnostics.finish_timing
         t.diagnostics
         Diagnostics.Drain
         ~trace_tid:t.session_id
         ~trace_args:
           [ Diagnostics.Int_arg ("session_id", t.session_id)
           ; Diagnostics.Int_arg ("frames", 0)
           ; Diagnostics.Int_arg ("bytes", 0)
           ]
         drain_timing;
       Diagnostics.record_flush_skip_empty t.diagnostics;
       Diagnostics.record_trace_instant
         t.diagnostics
         ~name:"flush_skip_empty"
         ~trace_tid:t.session_id
         ~trace_args:(flush_args ~status:"skip_empty" []);
       Mvar.set t.cap_mvar capability;
       finish_flush ~status:"skip_empty" [];
       return ()
     | Some d ->
       Diagnostics.finish_timing
         t.diagnostics
         Diagnostics.Drain
         ~trace_tid:t.session_id
         ~trace_args:
           [ Diagnostics.Int_arg ("session_id", t.session_id)
           ; Diagnostics.Int_arg ("frames", d.frame_count)
           ; Diagnostics.Int_arg ("bytes", d.body_len)
           ; Diagnostics.Int_arg ("oldest_seq", d.oldest_seq)
           ; Diagnostics.Int_arg ("newest_seq", d.newest_seq)
           ]
         drain_timing;
       Diagnostics.record_batch t.diagnostics ~frames:d.frame_count ~bytes:d.body_len;
       Diagnostics.record_trace_instant
         t.diagnostics
         ~name:"batch_ready"
         ~trace_tid:t.session_id
         ~trace_args:
           (flush_args
              ~status:"batch"
              [ Diagnostics.Int_arg ("frames", d.frame_count)
              ; Diagnostics.Int_arg ("bytes", d.body_len)
              ; Diagnostics.Int_arg ("oldest_seq", d.oldest_seq)
              ; Diagnostics.Int_arg ("newest_seq", d.newest_seq)
              ]);
       let inference_start = Time_ns.now () in
       let inference_timing =
         Diagnostics.start_timing t.diagnostics Diagnostics.Inference
       in
       Inference.send
         ~trace_tid:t.session_id
         t.inference
         ~conn:t.inf_conn
         ~capability
         ~body:d.body
         ~body_len:d.body_len
       >>= fun outcome ->
       let inference_elapsed_ms = ms_since inference_start in
       Diagnostics.finish_timing
         t.diagnostics
         Diagnostics.Inference
         ~trace_tid:t.session_id
         ~trace_args:
           [ Diagnostics.Int_arg ("frames", d.frame_count)
           ; Diagnostics.Int_arg ("bytes", d.body_len)
           ; Diagnostics.Int_arg ("oldest_seq", d.oldest_seq)
           ; Diagnostics.Int_arg ("newest_seq", d.newest_seq)
           ; Diagnostics.Float_arg ("flush_lateness_ms", flush_lateness_ms)
           ; Diagnostics.Float_arg ("elapsed_ms", inference_elapsed_ms)
           ]
         inference_timing;
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
           emit t (serialize_partial t partial)
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
           emit t (serialize_error t envelope)
       in
       Mvar.set t.cap_mvar (Inflight_capability.of_token outcome.token);
       finish_flush
         ~status:"sent"
         [ Diagnostics.Int_arg ("frames", d.frame_count)
         ; Diagnostics.Int_arg ("bytes", d.body_len)
         ; Diagnostics.Int_arg ("oldest_seq", d.oldest_seq)
         ; Diagnostics.Int_arg ("newest_seq", d.newest_seq)
         ];
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
