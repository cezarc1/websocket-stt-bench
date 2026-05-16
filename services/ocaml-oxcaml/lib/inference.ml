open! Core
open! Async

type t =
  { host : string
  ; port : int
  ; cpu_passes_header : string
  }

let create (config : Config.t) =
  { host = config.inference_host
  ; port = config.inference_port
  ; cpu_passes_header = Int.to_string config.cpu_passes
  }
;;

(* Matches the Rust gateway's 2 s request deadline. The inference simulator's p99 is ~300
   ms (75 ms model delay + batch wait + long tail), so 2 s is generous headroom while
   still bounding a true stall. *)
let request_timeout = Time_ns.Span.of_ms 2000.

type error =
  { stage : string
  ; kind : string
  ; message : string
  ; status : int option
  }

type outcome =
  { result : (Protocol.Infer_response.t, error) Result.t
  ; token : Inflight_capability.Token.t
  }

let request_stage = "inference_request"
let parse_stage = "inference_response_parse"

let parse_status_line line =
  match String.split line ~on:' ' with
  | _ :: code :: _ -> Int.of_string_opt code
  | _ -> None
;;

let skip_headers reader =
  let rec loop () =
    match%bind Reader.read_line reader with
    | `Eof -> return ()
    | `Ok "" -> return ()
    | `Ok _ -> loop ()
  in
  loop ()
;;

let read_body reader =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match%bind Reader.read reader chunk with
    | `Eof -> return (Buffer.contents buf)
    | `Ok n ->
      Buffer.add_subbytes buf chunk ~pos:0 ~len:n;
      loop ()
  in
  loop ()
;;

(* Shared wire vocab has only http_429 / http_5xx buckets; non-429 statuses (incl. 4xx)
   bucket as http_5xx, matching Rust/Go. The retryable distinction for 4xx is made in
   session.ml from the status. *)
let http_kind status = if status = 429 then "http_429" else "http_5xx"

let do_post t ~payload =
  let where =
    Tcp.Where_to_connect.of_host_and_port { Host_and_port.host = t.host; port = t.port }
  in
  Tcp.with_connection where (fun _socket reader writer ->
    let body_len = Bigstring.length payload in
    let request =
      sprintf
        "POST /infer HTTP/1.1\r\n\
         Host: %s:%d\r\n\
         x-cpu-passes: %s\r\n\
         Content-Type: application/octet-stream\r\n\
         Content-Length: %d\r\n\
         Connection: close\r\n\
         \r\n"
        t.host
        t.port
        t.cpu_passes_header
        body_len
    in
    Writer.write writer request;
    Writer.write_bigstring writer payload;
    let%bind () = Writer.flushed writer in
    match%bind Reader.read_line reader with
    | `Eof ->
      return
        (Error
           { stage = request_stage
           ; kind = "connection_reset"
           ; message = "eof on status line"
           ; status = None
           })
    | `Ok status_line ->
      (match parse_status_line status_line with
       | None ->
         return
           (Error
              { stage = parse_stage
              ; kind = "parse_error"
              ; message = sprintf "bad status line: %s" status_line
              ; status = None
              })
       | Some status when status <> 200 ->
         let%bind () = skip_headers reader in
         let%bind (_ : string) = read_body reader in
         return
           (Error
              { stage = request_stage
              ; kind = http_kind status
              ; message = sprintf "inference returned HTTP %d" status
              ; status = Some status
              })
       | Some _ ->
         let%bind () = skip_headers reader in
         let%bind body = read_body reader in
         (match Yojson.Safe.from_string body with
          | exception exn ->
            return
              (Error
                 { stage = parse_stage
                 ; kind = "parse_error"
                 ; message = sprintf "yojson: %s" (Exn.to_string exn)
                 ; status = None
                 })
          | json ->
            (match Protocol.Infer_response.of_yojson json with
             | Ok infer -> return (Ok infer)
             | Error msg ->
               return
                 (Error
                    { stage = parse_stage
                    ; kind = "parse_error"
                    ; message = msg
                    ; status = None
                    })))))
;;

let send t ~capability ~payload =
  let token = Inflight_capability.consume capability in
  let attempt =
    Monitor.try_with ~here:[%here] (fun () ->
      Clock_ns.with_timeout request_timeout (do_post t ~payload))
  in
  match%map attempt with
  | Ok (`Result result) -> { result; token }
  | Ok `Timeout ->
    { result =
        Error
          { stage = request_stage
          ; kind = "timeout"
          ; message =
              sprintf "inference exceeded %.0fms" (Time_ns.Span.to_ms request_timeout)
          ; status = None
          }
    ; token
    }
  | Error exn ->
    { result =
        Error
          { stage = request_stage
          ; kind = "connection_reset"
          ; message = Exn.to_string exn
          ; status = None
          }
    ; token
    }
;;
