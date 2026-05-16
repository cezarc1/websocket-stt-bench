open! Core

type t =
  { port : int
  ; inference_host : string
  ; inference_port : int
  ; inference_http_clients : int
  ; worker_threads : int
  ; flush_interval_ms : int
  ; flush_phase_jitter_ms : int
  ; cpu_passes : int
  ; model_delay_ms : int
  }

let env_int name ~default =
  match Sys.getenv name with
  | None -> default
  | Some value ->
    (match Int.of_string_opt value with
     | Some n -> n
     | None -> failwithf "env %s: expected integer, got %S" name value ())
;;

let env_string name ~default = Sys.getenv name |> Option.value ~default

(* Parse "http://host:port" or "host:port" or just "host" into (host, port). Tiny ad-hoc
   parser; we don't need a URI type for this. *)
let parse_inference_url s =
  let stripped =
    match String.chop_prefix s ~prefix:"http://" with
    | Some rest -> rest
    | None -> s
  in
  let stripped =
    match String.chop_suffix stripped ~suffix:"/" with
    | Some rest -> rest
    | None -> stripped
  in
  match String.lsplit2 stripped ~on:':' with
  | Some (host, port_str) ->
    (match Int.of_string_opt port_str with
     | Some port -> host, port
     | None -> stripped, 80)
  | None -> stripped, 80
;;

let from_env () =
  let url = env_string "INFERENCE_URL" ~default:"http://inference-server:9000" in
  let inference_host, inference_port = parse_inference_url url in
  { port = env_int "PORT" ~default:9000
  ; inference_host
  ; inference_port
  ; inference_http_clients = env_int "INFERENCE_HTTP_CLIENTS" ~default:4
  ; worker_threads = env_int "WORKER_THREADS" ~default:1
  ; flush_interval_ms = env_int "FLUSH_INTERVAL_MS" ~default:1000
  ; flush_phase_jitter_ms = env_int "FLUSH_PHASE_JITTER_MS" ~default:0
  ; cpu_passes = env_int "CPU_PASSES" ~default:4
  ; model_delay_ms = env_int "MODEL_DELAY_MS" ~default:75
  }
;;

let to_string_hum t =
  String.concat
    ~sep:" "
    [ sprintf "port=%d" t.port
    ; sprintf "inference=%s:%d" t.inference_host t.inference_port
    ; sprintf "inference_http_clients=%d" t.inference_http_clients
    ; sprintf "worker_threads=%d" t.worker_threads
    ; sprintf "flush_interval_ms=%d" t.flush_interval_ms
    ; sprintf "flush_phase_jitter_ms=%d" t.flush_phase_jitter_ms
    ; sprintf "cpu_passes=%d" t.cpu_passes
    ; sprintf "model_delay_ms=%d" t.model_delay_ms
    ]
;;
