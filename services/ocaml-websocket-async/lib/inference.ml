open! Core
open! Async

type t =
  { header_prefix : string
  ; where : Tcp.Where_to_connect.inet
  }

(* Everything in the request head except [Content-Length] is constant for the life of the
   process, so build it once instead of per flush. *)
let create (config : Config.t) =
  { header_prefix =
      sprintf
        "POST /infer HTTP/1.1\r\n\
         Host: %s:%d\r\n\
         x-cpu-passes: %d\r\n\
         Content-Type: application/octet-stream\r\n"
        config.inference_host
        config.inference_port
        config.cpu_passes
  ; where =
      Tcp.Where_to_connect.of_host_and_port
        { Host_and_port.host = config.inference_host; port = config.inference_port }
  }
;;

(* Matches the Rust gateway's 2 s request deadline. The inference simulator's p99 is ~300
   ms (75 ms model delay + batch wait + long tail), so 2 s is generous headroom while
   still bounding a stall. *)
let request_timeout = Time_ns.Span.of_ms 2000.

(* [epoch] fences a request against the connection generation [send] observed when it
   started. Async cannot cancel the in-flight [do_request] when [Clock_ns.with_timeout]
   fires, so [send] bumps [epoch] on timeout/exn; the abandoned request then sees a stale
   epoch and must not mutate [conn] or reuse/redial its socket (otherwise it could resend
   the batch onto the next flush's connection — the bug the timeout path used to have). *)
type conn =
  { mutable rw : (Reader.t * Writer.t) option
  ; mutable epoch : int
  }

let create_conn () = { rw = None; epoch = 0 }

let close_rw (reader, writer) =
  let%bind () = Writer.close writer in
  Reader.close reader
;;

let close_conn conn =
  match conn.rw with
  | None -> return ()
  | Some rw ->
    conn.rw <- None;
    close_rw rw
;;

module Stage = Protocol.Error_stage
module Kind = Protocol.Error_kind

type error =
  { stage : Stage.t
  ; kind : Kind.t
  ; message : string
  ; status : int option
  }

type outcome = { result : (Protocol.Infer_response.t, error) Result.t }

let err ~stage ~kind ~message ~status = Error { stage; kind; message; status }

let parse_err message =
  err ~stage:Stage.Inference_response_parse ~kind:Kind.Parse_error ~message ~status:None
;;

let connection_reset message =
  err ~stage:Stage.Inference_request ~kind:Kind.Connection_reset ~message ~status:None
;;

let parse_status_line line =
  match String.split line ~on:' ' with
  | _ :: code :: _ -> Int.of_string_opt code
  | _ -> None
;;

(* With keep-alive the body must be framed by Content-Length (not read-to-EOF) or the next
   request on the same socket desyncs. A chunked response would also desync our framed
   reader, so reject it rather than silently mis-parse — the inference server (axum)
   always sends Content-Length for our small JSON, so this is purely defensive. *)
let read_response_head reader =
  match%bind Reader.read_line reader with
  | `Eof -> return `Closed
  | `Ok status_line ->
    (match parse_status_line status_line with
     | None -> return (`Bad_status status_line)
     | Some status ->
       (match%bind Http1.read_headers reader with
        | `Eof -> return `Closed
        | `Ok headers ->
          (match Http1.find headers "transfer-encoding" with
           | Some _ -> return `Chunked_unsupported
           | None ->
             (match Http1.find headers "content-length" with
              | None -> return `No_length
              | Some v ->
                (match Int.of_string_opt v with
                 | Some len -> return (`Ok (status, len))
                 | None -> return `No_length)))))
;;

let read_exact reader ~len =
  let buf = Bytes.create len in
  match%bind Reader.really_read reader ~len buf with
  | `Eof _ -> return None
  (* [buf] is freshly allocated here and not mutated after the read, so handing it off as
     an immutable string with [unsafe_to_string] avoids a copy and is sound. *)
  | `Ok -> return (Some (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:buf))
;;

let write_request t writer ~body ~body_len =
  (* HTTP/1.1 default is keep-alive — no [Connection: close]. The frame strings are
     written sequentially after the head; the Writer buffers them so this is a single
     flush, no concat allocation. *)
  Writer.write writer t.header_prefix;
  Writer.write writer (sprintf "Content-Length: %d\r\n\r\n" body_len);
  List.iter body ~f:(fun s -> Writer.write writer s);
  Writer.flushed writer
;;

(* One request/response on an established [(reader, writer)]. [`Retry] means the socket
   looked dead (EOF before/within the response) so the caller may redial once. *)
let exchange t (reader, writer) ~body ~body_len =
  match%bind
    Monitor.try_with ~here:[%here] (fun () -> write_request t writer ~body ~body_len)
  with
  | Error _ -> return `Retry
  | Ok () ->
    (match%bind read_response_head reader with
     | `Closed -> return `Retry
     | `Bad_status line -> return (`Done (parse_err (sprintf "bad status line: %s" line)))
     | `Chunked_unsupported ->
       return (`Done (parse_err "chunked transfer-encoding not supported"))
     | `No_length -> return (`Done (parse_err "missing Content-Length"))
     | `Ok (status, len) ->
       (match%bind read_exact reader ~len with
        | None -> return `Retry
        | Some resp_body ->
          if status <> 200
          then
            return
              (`Done
                  (err
                     ~stage:Stage.Inference_request
                     ~kind:(if status = 429 then Kind.Http_429 else Kind.Http_5xx)
                     ~message:(sprintf "inference returned HTTP %d" status)
                     ~status:(Some status)))
          else (
            match Yojson.Safe.from_string resp_body with
            | exception exn ->
              return (`Done (parse_err (sprintf "yojson: %s" (Exn.to_string exn))))
            | json ->
              (match Protocol.Infer_response.of_yojson json with
               | Ok infer -> return (`Done (Ok infer))
               | Error msg -> return (`Done (parse_err msg))))))
;;

let dial t = Tcp.connect t.where >>| fun (_sock, r, w) -> r, w

(* Reuse the session's keep-alive socket; redial once if it is stale/closed (idle
   keep-alive timeout, server restart, …). A request abandoned by [send]'s timeout/exn
   path carries a stale [epoch] ([current ()] is false); it must not publish into
   [conn.rw] or close the shared socket, so it just closes any socket it personally dialed
   and bails. The next [send] cannot begin until the owning [send] returns (Mvar/token
   discipline in {!Session}), so once superseded the orphan can never reach a live epoch
   again — there is no later connection for it to clobber. *)
let do_request t conn ~epoch ~body ~body_len =
  let current () = conn.epoch = epoch in
  (* Publish a freshly dialed socket for reuse only if this attempt still owns [conn]; the
     [current ()] check and the [conn.rw] write are adjacent with no intervening bind —
     that synchronicity is the epoch-fence invariant. *)
  let publish_or_abandon rw =
    if current ()
    then (
      conn.rw <- Some rw;
      return (`Use rw))
    else (
      let%bind () = close_rw rw in
      return `Abandoned)
  in
  let acquire () =
    match conn.rw with
    | Some rw -> return (`Use rw)
    | None ->
      let%bind rw = dial t in
      publish_or_abandon rw
  in
  let redial () =
    if not (current ())
    then return `Abandoned
    else (
      let%bind () = close_conn conn in
      let%bind rw = dial t in
      publish_or_abandon rw)
  in
  match%bind acquire () with
  | `Abandoned -> return (connection_reset "inference connection abandoned")
  | `Use rw ->
    (match%bind exchange t rw ~body ~body_len with
     | `Done result -> return result
     | `Retry ->
       (match%bind redial () with
        | `Abandoned -> return (connection_reset "inference connection abandoned")
        | `Use rw ->
          (match%bind exchange t rw ~body ~body_len with
           | `Done result -> return result
           | `Retry ->
             let%bind () = if current () then close_conn conn else return () in
             return (connection_reset "inference connection failed after redial"))))
;;

let send t ~conn ~body ~body_len =
  let epoch = conn.epoch in
  let abandon kind message =
    conn.epoch <- conn.epoch + 1;
    let%bind () = close_conn conn in
    return { result = err ~stage:Stage.Inference_request ~kind ~message ~status:None }
  in
  match%bind
    Monitor.try_with ~here:[%here] (fun () ->
      Clock_ns.with_timeout request_timeout (do_request t conn ~epoch ~body ~body_len))
  with
  | Ok (`Result result) -> return { result }
  | Ok `Timeout ->
    abandon
      Kind.Timeout
      (sprintf "inference exceeded %.0fms" (Time_ns.Span.to_ms request_timeout))
  | Error exn -> abandon Kind.Connection_reset (Exn.to_string exn)
;;
