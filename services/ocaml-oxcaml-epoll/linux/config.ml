type t =
  { port : int
  ; inference_host : string
  ; inference_port : int
  ; inference_http_clients : int
  ; cpu_passes : int
  ; model_delay_ms : int
  ; flush_interval_ms : int
  ; flush_phase_jitter_ms : int
  }

let int_env name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s ->
    (try int_of_string s with
     | Failure _ -> default)
;;

let string_env name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s -> s
;;

let parse_url s =
  let s =
    if String.length s >= 7 && String.sub s 0 7 = "http://"
    then String.sub s 7 (String.length s - 7)
    else s
  in
  let s =
    match String.index_opt s '/' with
    | None -> s
    | Some i -> String.sub s 0 i
  in
  match String.rindex_opt s ':' with
  | Some i ->
    let host = String.sub s 0 i in
    let port_s = String.sub s (i + 1) (String.length s - i - 1) in
    (try host, int_of_string port_s with
     | Failure _ -> s, 80)
  | None -> s, 80
;;

let load () =
  let inference_host, inference_port =
    parse_url (string_env "INFERENCE_URL" "http://inference-server:9000")
  in
  { port = int_env "PORT" 9200
  ; inference_host
  ; inference_port
  ; inference_http_clients = max 1 (int_env "INFERENCE_HTTP_CLIENTS" 1024)
  ; cpu_passes = max 1 (int_env "CPU_PASSES" 4)
  ; model_delay_ms = max 0 (int_env "MODEL_DELAY_MS" 75)
  ; flush_interval_ms = max 1 (int_env "FLUSH_INTERVAL_MS" 1000)
  ; flush_phase_jitter_ms = max 0 (int_env "FLUSH_PHASE_JITTER_MS" 0)
  }
;;
