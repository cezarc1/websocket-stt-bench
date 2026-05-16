open! Core
open! Async

type t =
  { host : string
  ; port : int
  ; cpu_passes_header : string
  ; where : Tcp.Where_to_connect.inet
  }

let create (config : Config.t) =
  { host = config.inference_host
  ; port = config.inference_port
  ; cpu_passes_header = Int.to_string config.cpu_passes
  ; where =
      Tcp.Where_to_connect.of_host_and_port
        { Host_and_port.host = config.inference_host; port = config.inference_port }
  }
;;

(* Matches the Rust gateway's 2 s request deadline. The inference simulator's p99 is ~300
   ms (75 ms model delay + batch wait + long tail), so 2 s is generous headroom while
   still bounding a stall. *)
let request_timeout = Time_ns.Span.of_ms 2000.

type conn = { mutable rw : (Reader.t * Writer.t) option }

let create_conn () = { rw = None }

let close_conn conn =
  match conn.rw with
  | None -> return ()
  | Some (reader, writer) ->
    conn.rw <- None;
    let%bind () = Writer.close writer in
    Reader.close reader
;;

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
let err ~stage ~kind ~message ~status = Error { stage; kind; message; status }

let parse_status_line line =
  match String.split line ~on:' ' with
  | _ :: code :: _ -> Int.of_string_opt code
  | _ -> None
;;

(* Read status code + Content-Length. With keep-alive we must frame the body by
   Content-Length (not read-to-EOF), or the next request on the same connection would
   desync. *)
let read_response_head reader =
  match%bind Reader.read_line reader with
  | `Eof -> return (`Closed `Status)
  | `Ok status_line ->
    (match parse_status_line status_line with
     | None -> return (`Bad_status status_line)
     | Some status ->
       let rec headers content_length =
         match%bind Reader.read_line reader with
         | `Eof -> return (`Closed `Headers)
         | `Ok "" -> return (`Ok (status, content_length))
         | `Ok line ->
           (match String.lsplit2 line ~on:':' with
            | Some (k, v) when String.Caseless.equal (String.strip k) "content-length" ->
              headers (Int.of_string_opt (String.strip v))
            | _ -> headers content_length)
       in
       headers None)
;;

let read_exact reader ~len =
  let buf = Bytes.create len in
  match%bind Reader.really_read reader ~len buf with
  | `Eof _ -> return None
  | `Ok -> return (Some (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:buf))
;;

let write_request t writer ~body ~body_len =
  (* HTTP/1.1 default is keep-alive — no [Connection: close]. The frame strings are
     written sequentially after the head; the Writer buffers them so this is a single
     flush, no concat allocation. *)
  Writer.write
    writer
    (sprintf
       "POST /infer HTTP/1.1\r\n\
        Host: %s:%d\r\n\
        x-cpu-passes: %s\r\n\
        Content-Type: application/octet-stream\r\n\
        Content-Length: %d\r\n\
        \r\n"
       t.host
       t.port
       t.cpu_passes_header
       body_len);
  List.iter body ~f:(fun s -> Writer.write writer s);
  Writer.flushed writer
;;

(* One request/response on an established (reader, writer). Returns [`Retry] when the
   connection looks dead (EOF before/within the response) so the caller can redial once. *)
let exchange t (reader, writer) ~body ~body_len =
  match%bind
    Monitor.try_with ~here:[%here] (fun () -> write_request t writer ~body ~body_len)
  with
  | Error _ -> return `Retry
  | Ok () ->
    (match%bind read_response_head reader with
     | `Closed _ -> return `Retry
     | `Bad_status line ->
       return
         (`Done
           (err
              ~stage:parse_stage
              ~kind:"parse_error"
              ~message:(sprintf "bad status line: %s" line)
              ~status:None))
     | `Ok (status, content_length) ->
       (match content_length with
        | None ->
          return
            (`Done
              (err
                 ~stage:parse_stage
                 ~kind:"parse_error"
                 ~message:"missing Content-Length"
                 ~status:None))
        | Some len ->
          (match%bind read_exact reader ~len with
           | None -> return `Retry
           | Some resp_body ->
             if status <> 200
             then
               return
                 (`Done
                   (err
                      ~stage:request_stage
                      ~kind:(if status = 429 then "http_429" else "http_5xx")
                      ~message:(sprintf "inference returned HTTP %d" status)
                      ~status:(Some status)))
             else (
               match Yojson.Safe.from_string resp_body with
               | exception exn ->
                 return
                   (`Done
                     (err
                        ~stage:parse_stage
                        ~kind:"parse_error"
                        ~message:(sprintf "yojson: %s" (Exn.to_string exn))
                        ~status:None))
               | json ->
                 (match Protocol.Infer_response.of_yojson json with
                  | Ok infer -> return (`Done (Ok infer))
                  | Error msg ->
                    return
                      (`Done
                        (err
                           ~stage:parse_stage
                           ~kind:"parse_error"
                           ~message:msg
                           ~status:None)))))))
;;

let dial t = Tcp.connect t.where >>| fun (_sock, r, w) -> r, w

let do_request t conn ~body ~body_len =
  (* Reuse the session's keep-alive connection; redial once if it's stale/closed (idle
     keep-alive timeout, server restart, etc.). *)
  let attempt rw =
    exchange t rw ~body ~body_len
    >>= function
    | `Done result -> return (`Done result)
    | `Retry -> return `Retry
  in
  let%bind first =
    match conn.rw with
    | Some rw -> attempt rw
    | None ->
      let%bind rw = dial t in
      conn.rw <- Some rw;
      attempt rw
  in
  match first with
  | `Done result -> return result
  | `Retry ->
    let%bind () = close_conn conn in
    let%bind rw = dial t in
    conn.rw <- Some rw;
    (match%bind attempt rw with
     | `Done result -> return result
     | `Retry ->
       let%bind () = close_conn conn in
       return
         (err
            ~stage:request_stage
            ~kind:"connection_reset"
            ~message:"inference connection failed after redial"
            ~status:None))
;;

let send t ~conn ~capability ~body ~body_len =
  let token = Inflight_capability.consume capability in
  match%bind
    Monitor.try_with ~here:[%here] (fun () ->
      Clock_ns.with_timeout request_timeout (do_request t conn ~body ~body_len))
  with
  | Ok (`Result result) -> return { result; token }
  | Ok `Timeout ->
    let%bind () = close_conn conn in
    return
      { result =
          err
            ~stage:request_stage
            ~kind:"timeout"
            ~message:
              (sprintf "inference exceeded %.0fms" (Time_ns.Span.to_ms request_timeout))
            ~status:None
      ; token
      }
  | Error exn ->
    let%bind () = close_conn conn in
    return
      { result =
          err
            ~stage:request_stage
            ~kind:"connection_reset"
            ~message:(Exn.to_string exn)
            ~status:None
      ; token
      }
;;
