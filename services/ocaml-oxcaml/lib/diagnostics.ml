open! Core
open! Async

module Config = struct
  type t =
    { enabled : bool
    ; interval_ms : int
    ; sample_every : int
    ; trace_enabled : bool
    ; trace_file : string option
    ; trace_sample_every : int
    ; trace_flush_interval_ms : int
    ; trace_frame_sample_every : int
    ; trace_max_events : int
    }

  let default_interval_ms = 5000
  let default_sample_every = 100
  let default_trace_sample_every = 100
  let default_trace_flush_interval_ms = 1000
  let default_trace_frame_sample_every = 500
  let default_trace_max_events = 200_000

  let disabled =
    { enabled = false
    ; interval_ms = default_interval_ms
    ; sample_every = default_sample_every
    ; trace_enabled = false
    ; trace_file = None
    ; trace_sample_every = default_trace_sample_every
    ; trace_flush_interval_ms = default_trace_flush_interval_ms
    ; trace_frame_sample_every = default_trace_frame_sample_every
    ; trace_max_events = default_trace_max_events
    }
  ;;

  let positive_int_or_default raw ~default =
    match raw with
    | None -> default
    | Some value ->
      (match Int.of_string_opt value with
       | Some n when n > 0 -> n
       | _ -> default)
  ;;

  let nonempty_string = function
    | Some value when not (String.is_empty value) -> Some value
    | _ -> None
  ;;

  let enabled_flag getenv name =
    match getenv name with
    | Some "1" -> true
    | _ -> false
  ;;

  let of_getenv getenv =
    { enabled = enabled_flag getenv "OXCAML_DIAG"
    ; interval_ms =
        positive_int_or_default
          (getenv "OXCAML_DIAG_INTERVAL_MS")
          ~default:default_interval_ms
    ; sample_every =
        positive_int_or_default
          (getenv "OXCAML_DIAG_SAMPLE_EVERY")
          ~default:default_sample_every
    ; trace_enabled = enabled_flag getenv "OXCAML_TRACE"
    ; trace_file = nonempty_string (getenv "OXCAML_TRACE_FILE")
    ; trace_sample_every =
        positive_int_or_default
          (getenv "OXCAML_TRACE_SAMPLE_EVERY")
          ~default:default_trace_sample_every
    ; trace_flush_interval_ms =
        positive_int_or_default
          (getenv "OXCAML_TRACE_FLUSH_INTERVAL_MS")
          ~default:default_trace_flush_interval_ms
    ; trace_frame_sample_every =
        positive_int_or_default
          (getenv "OXCAML_TRACE_FRAME_SAMPLE_EVERY")
          ~default:default_trace_frame_sample_every
    ; trace_max_events =
        positive_int_or_default
          (getenv "OXCAML_TRACE_MAX_EVENTS")
          ~default:default_trace_max_events
    }
  ;;

  let from_env () = of_getenv Sys.getenv
end

type counters =
  { mutable sessions_opened : int
  ; mutable sessions_closed : int
  ; mutable binary_frames : int
  ; mutable binary_bytes : int
  ; mutable flush_ticks : int
  ; mutable flush_skip_inflight : int
  ; mutable flush_skip_empty : int
  ; mutable batches : int
  ; mutable batch_frames : int
  ; mutable batch_bytes : int
  }

let create_counters () =
  { sessions_opened = 0
  ; sessions_closed = 0
  ; binary_frames = 0
  ; binary_bytes = 0
  ; flush_ticks = 0
  ; flush_skip_inflight = 0
  ; flush_skip_empty = 0
  ; batches = 0
  ; batch_frames = 0
  ; batch_bytes = 0
  }
;;

type timing =
  { mutable seen : int
  ; mutable samples : int
  ; mutable total_ms : float
  ; mutable max_ms : float
  }

let create_timing () = { seen = 0; samples = 0; total_ms = 0.0; max_ms = 0.0 }

type timing_metric =
  | Inference
  | Flush_cycle
  | Drain
  | Inference_write
  | Inference_read_head
  | Inference_read_body
  | Serialization
  | Outbound_write
  | Response_parse

type timing_sample =
  | No_sample
  | Sample of
      { started_at : Time_ns.t
      ; record_metric : bool
      ; record_trace : bool
      }

type trace_arg =
  | Int_arg of string * int
  | Float_arg of string * float
  | String_arg of string * string
  | Bool_arg of string * bool

type trace_state =
  { mutable events_rev : Chrome_trace.Event.t list
  ; mutable event_count : int
  ; mutable dropped_events : int
  }

type t =
  { config : Config.t
  ; started_at : Time_ns.t
  ; pid : int
  ; gc_start : Stdlib.Gc.stat
  ; counters : counters
  ; mutable next_session_id : int
  ; inference : timing
  ; flush_cycle : timing
  ; drain : timing
  ; inference_write : timing
  ; inference_read_head : timing
  ; inference_read_body : timing
  ; serialization : timing
  ; outbound_write : timing
  ; response_parse : timing
  ; trace : trace_state
  }

let create config =
  { config
  ; started_at = Time_ns.now ()
  ; pid = Core_unix.getpid () |> Pid.to_int
  ; gc_start = Stdlib.Gc.quick_stat ()
  ; counters = create_counters ()
  ; next_session_id = 0
  ; inference = create_timing ()
  ; flush_cycle = create_timing ()
  ; drain = create_timing ()
  ; inference_write = create_timing ()
  ; inference_read_head = create_timing ()
  ; inference_read_body = create_timing ()
  ; serialization = create_timing ()
  ; outbound_write = create_timing ()
  ; response_parse = create_timing ()
  ; trace = { events_rev = []; event_count = 0; dropped_events = 0 }
  }
;;

let disabled = create Config.disabled
let enabled t = t.config.enabled
let tracing_enabled t = t.config.trace_enabled
let if_enabled t f = if t.config.enabled then f ()

let timestamp_since_start t time =
  Time_ns.diff time t.started_at
  |> Time_ns.Span.to_sec
  |> Chrome_trace.Event.Timestamp.of_float_seconds
;;

let trace_arg_to_chrome = function
  | Int_arg (name, value) -> name, `Int value
  | Float_arg (name, value) -> name, `Float value
  | String_arg (name, value) -> name, `String value
  | Bool_arg (name, value) -> name, `Bool value
;;

let add_trace_event t event =
  if t.trace.event_count >= t.config.trace_max_events
  then t.trace.dropped_events <- t.trace.dropped_events + 1
  else (
    t.trace.events_rev <- event :: t.trace.events_rev;
    t.trace.event_count <- t.trace.event_count + 1)
;;

let trace_common_fields t ~name ~trace_tid =
  Chrome_trace.Event.common_fields
    ~cat:[ "oxcaml"; "gateway" ]
    ~pid:t.pid
    ~tid:trace_tid
    ~ts:(timestamp_since_start t (Time_ns.now ()))
    ~name
    ()
;;

let trace_args_to_chrome trace_args = List.map trace_args ~f:trace_arg_to_chrome

let record_trace_instant t ~name ~trace_tid ~trace_args =
  if t.config.trace_enabled
  then
    trace_common_fields t ~name ~trace_tid
    |> Chrome_trace.Event.instant
         ~scope:Chrome_trace.Event.Thread
         ~args:(trace_args_to_chrome trace_args)
    |> add_trace_event t
;;

let record_trace_counter t ~name ~trace_tid ~trace_args =
  if t.config.trace_enabled
  then
    Chrome_trace.Event.counter
      (trace_common_fields t ~name ~trace_tid)
      (trace_args_to_chrome trace_args)
    |> add_trace_event t
;;

let record_session_opened t =
  t.next_session_id <- t.next_session_id + 1;
  let session_id = t.next_session_id in
  if_enabled t (fun () -> t.counters.sessions_opened <- t.counters.sessions_opened + 1);
  record_trace_instant
    t
    ~name:"session_open"
    ~trace_tid:session_id
    ~trace_args:[ Int_arg ("session_id", session_id) ];
  session_id
;;

let record_session_closed t ~session_id =
  if_enabled t (fun () -> t.counters.sessions_closed <- t.counters.sessions_closed + 1);
  record_trace_instant
    t
    ~name:"session_close"
    ~trace_tid:session_id
    ~trace_args:[ Int_arg ("session_id", session_id) ]
;;

let record_binary_frame t ~session_id ~seq ~bytes =
  if_enabled t (fun () ->
    t.counters.binary_frames <- t.counters.binary_frames + 1;
    t.counters.binary_bytes <- t.counters.binary_bytes + bytes);
  if t.config.trace_enabled
     && t.config.trace_frame_sample_every > 0
     && seq % t.config.trace_frame_sample_every = 0
  then
    record_trace_instant
      t
      ~name:"binary_frame"
      ~trace_tid:session_id
      ~trace_args:
        [ Int_arg ("session_id", session_id)
        ; Int_arg ("seq", seq)
        ; Int_arg ("bytes", bytes)
        ]
;;

let record_flush_tick t =
  if_enabled t (fun () -> t.counters.flush_ticks <- t.counters.flush_ticks + 1)
;;

let record_flush_skip_inflight t =
  if_enabled t (fun () ->
    t.counters.flush_skip_inflight <- t.counters.flush_skip_inflight + 1)
;;

let record_flush_skip_empty t =
  if_enabled t (fun () -> t.counters.flush_skip_empty <- t.counters.flush_skip_empty + 1)
;;

let record_batch t ~frames ~bytes =
  if_enabled t (fun () ->
    t.counters.batches <- t.counters.batches + 1;
    t.counters.batch_frames <- t.counters.batch_frames + frames;
    t.counters.batch_bytes <- t.counters.batch_bytes + bytes)
;;

let timing t = function
  | Inference -> t.inference
  | Flush_cycle -> t.flush_cycle
  | Drain -> t.drain
  | Inference_write -> t.inference_write
  | Inference_read_head -> t.inference_read_head
  | Inference_read_body -> t.inference_read_body
  | Serialization -> t.serialization
  | Outbound_write -> t.outbound_write
  | Response_parse -> t.response_parse
;;

let timing_metric_name = function
  | Inference -> "inference"
  | Flush_cycle -> "flush_cycle"
  | Drain -> "drain"
  | Inference_write -> "inference_write"
  | Inference_read_head -> "inference_read_head"
  | Inference_read_body -> "inference_read_body"
  | Serialization -> "serialization"
  | Outbound_write -> "outbound_write"
  | Response_parse -> "response_parse"
;;

let start_timing t metric =
  if (not t.config.enabled) && not t.config.trace_enabled
  then No_sample
  else (
    let timing = timing t metric in
    timing.seen <- timing.seen + 1;
    let record_metric =
      t.config.enabled && (timing.seen = 1 || timing.seen % t.config.sample_every = 0)
    in
    let record_trace =
      t.config.trace_enabled
      && (timing.seen = 1 || timing.seen % t.config.trace_sample_every = 0)
    in
    if record_metric || record_trace
    then Sample { started_at = Time_ns.now (); record_metric; record_trace }
    else No_sample)
;;

let record_trace_span t metric ~started_at ~elapsed ~trace_tid ~trace_args =
  let common =
    Chrome_trace.Event.common_fields
      ~cat:[ "oxcaml"; "gateway" ]
      ~pid:t.pid
      ~tid:trace_tid
      ~ts:(timestamp_since_start t started_at)
      ~name:(timing_metric_name metric)
      ()
  in
  let dur =
    elapsed |> Time_ns.Span.to_sec |> Chrome_trace.Event.Timestamp.of_float_seconds
  in
  let args = List.map trace_args ~f:trace_arg_to_chrome in
  Chrome_trace.Event.complete ~dur ~args common |> add_trace_event t
;;

let finish_timing t metric ?(trace_tid = 0) ?(trace_args = []) = function
  | No_sample -> ()
  | Sample { started_at; record_metric; record_trace } ->
    let now = Time_ns.now () in
    let elapsed = Time_ns.diff now started_at in
    let timing = timing t metric in
    if record_metric
    then (
      let elapsed_ms = elapsed |> Time_ns.Span.to_ms in
      timing.samples <- timing.samples + 1;
      timing.total_ms <- timing.total_ms +. elapsed_ms;
      timing.max_ms <- Float.max timing.max_ms elapsed_ms);
    if record_trace
    then record_trace_span t metric ~started_at ~elapsed ~trace_tid ~trace_args
;;

let timing_json t =
  let avg_ms = if t.samples = 0 then 0.0 else t.total_ms /. Float.of_int t.samples in
  `Assoc
    [ "seen", `Int t.seen
    ; "samples", `Int t.samples
    ; "total_ms", `Float t.total_ms
    ; "max_ms", `Float t.max_ms
    ; "avg_ms", `Float avg_ms
    ]
;;

let counters_json c =
  `Assoc
    [ "sessions_opened", `Int c.sessions_opened
    ; "sessions_closed", `Int c.sessions_closed
    ; "binary_frames", `Int c.binary_frames
    ; "binary_bytes", `Int c.binary_bytes
    ; "flush_ticks", `Int c.flush_ticks
    ; "flush_skip_inflight", `Int c.flush_skip_inflight
    ; "flush_skip_empty", `Int c.flush_skip_empty
    ; "batches", `Int c.batches
    ; "batch_frames", `Int c.batch_frames
    ; "batch_bytes", `Int c.batch_bytes
    ]
;;

let gc_json t =
  let s = Stdlib.Gc.quick_stat () in
  `Assoc
    [ "minor_words_delta", `Float (s.minor_words -. t.gc_start.minor_words)
    ; "promoted_words_delta", `Float (s.promoted_words -. t.gc_start.promoted_words)
    ; "major_words_delta", `Float (s.major_words -. t.gc_start.major_words)
    ; "minor_collections_delta", `Int (s.minor_collections - t.gc_start.minor_collections)
    ; "major_collections_delta", `Int (s.major_collections - t.gc_start.major_collections)
    ; "compactions_delta", `Int (s.compactions - t.gc_start.compactions)
    ; "heap_words", `Int s.heap_words
    ; "top_heap_words", `Int s.top_heap_words
    ; "live_words", `Int s.live_words
    ; "free_words", `Int s.free_words
    ]
;;

let trace_file t =
  if not t.config.trace_enabled
  then None
  else
    Some
      (Option.value
         t.config.trace_file
         ~default:(sprintf "/tmp/oxcaml-trace-%d.json" t.pid))
;;

let rec yojson_of_chrome_json (json : Chrome_trace.Json.t) : Yojson.Safe.t =
  match json with
  | `Int n -> `Int n
  | `Float n -> `Float n
  | `String s -> `String s
  | `List items -> `List (List.map items ~f:yojson_of_chrome_json)
  | `Bool b -> `Bool b
  | `Assoc fields ->
    `Assoc (List.map fields ~f:(fun (name, value) -> name, yojson_of_chrome_json value))
  | `Null -> `Null
;;

let trace_metadata_json t =
  [ "sample_every", `Int t.config.trace_sample_every
  ; "frame_sample_every", `Int t.config.trace_frame_sample_every
  ; "max_events", `Int t.config.trace_max_events
  ; "dropped_events", `Int t.trace.dropped_events
  ; "pid", `Int t.pid
  ]
;;

let trace_json t =
  Chrome_trace.Output_object.create
    ~displayTimeUnit:`Ms
    ~extra_fields:(trace_metadata_json t)
    ~traceEvents:(List.rev t.trace.events_rev)
    ()
  |> Chrome_trace.Output_object.to_json
  |> yojson_of_chrome_json
;;

let trace_json_for_test t =
  if not t.config.trace_enabled then None else Some (trace_json t |> Yojson.Safe.to_string)
;;

let write_trace_now t =
  match trace_file t with
  | None -> ()
  | Some file ->
    (try
       Out_channel.write_all file ~data:(trace_json t |> Yojson.Safe.pretty_to_string)
     with
     | exn ->
       Out_channel.eprintf
         "oxcaml trace write failed file=%s error=%s\n%!"
         file
         (Exn.to_string exn))
;;

let snapshot_json t =
  let uptime_ms = Time_ns.diff (Time_ns.now ()) t.started_at |> Time_ns.Span.to_ms in
  `Assoc
    [ "type", `String "oxcaml_diag"
    ; "enabled", `Bool t.config.enabled
    ; "interval_ms", `Int t.config.interval_ms
    ; "sample_every", `Int t.config.sample_every
    ; "pid", `Int t.pid
    ; "uptime_ms", `Float uptime_ms
    ; "counters", counters_json t.counters
    ; ( "timings"
      , `Assoc
          [ "inference", timing_json t.inference
          ; "flush_cycle", timing_json t.flush_cycle
          ; "drain", timing_json t.drain
          ; "inference_write", timing_json t.inference_write
          ; "inference_read_head", timing_json t.inference_read_head
          ; "inference_read_body", timing_json t.inference_read_body
          ; "serialization", timing_json t.serialization
          ; "outbound_write", timing_json t.outbound_write
          ; "response_parse", timing_json t.response_parse
          ] )
    ; "gc", gc_json t
    ; ( "trace"
      , `Assoc
          [ "enabled", `Bool t.config.trace_enabled
          ; ( "file"
            , Option.value_map (trace_file t) ~default:`Null ~f:(fun file -> `String file)
            )
          ; "sample_every", `Int t.config.trace_sample_every
          ; "flush_interval_ms", `Int t.config.trace_flush_interval_ms
          ; "frame_sample_every", `Int t.config.trace_frame_sample_every
          ; "max_events", `Int t.config.trace_max_events
          ; "events", `Int t.trace.event_count
          ; "dropped_events", `Int t.trace.dropped_events
          ] )
    ]
;;

let snapshot_json_for_test t = snapshot_json t |> Yojson.Safe.to_string

let emit_stderr t =
  Out_channel.output_string Out_channel.stderr (snapshot_json_for_test t);
  Out_channel.output_char Out_channel.stderr '\n';
  Out_channel.flush Out_channel.stderr
;;

let run_periodic t =
  if not t.config.enabled
  then return ()
  else (
    let interval = Time_ns.Span.of_ms (Float.of_int t.config.interval_ms) in
    let rec loop () =
      let%bind () = Clock_ns.after interval in
      emit_stderr t;
      loop ()
    in
    loop ())
;;

let run_trace_periodic t =
  if not t.config.trace_enabled
  then return ()
  else (
    write_trace_now t;
    let interval = Time_ns.Span.of_ms (Float.of_int t.config.trace_flush_interval_ms) in
    let rec loop () =
      let%bind () = Clock_ns.after interval in
      write_trace_now t;
      loop ()
    in
    loop ())
;;
