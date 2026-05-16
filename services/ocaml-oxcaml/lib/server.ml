open! Core
open! Async

let close_protocol_error = 1002
let ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

let read_start_message (frame : Ws_frame.t) =
  match frame.opcode with
  | Ws_frame.Text ->
    (match Yojson.Safe.from_string frame.payload with
     | exception _ -> Error "first frame: invalid JSON"
     | json ->
       (match Protocol.Start_message.of_yojson json with
        | Ok msg when String.equal msg.type_ "start" -> Ok ()
        | Ok _ -> Error "first frame: type must equal \"start\""
        | Error e -> Error e))
  | Ws_frame.Continuation
  | Ws_frame.Binary
  | Ws_frame.Close
  | Ws_frame.Ping
  | Ws_frame.Pong
  | Ws_frame.Other _ -> Error "first frame: expected text JSON"
;;

let close_session writer ~outbound_writer ~code =
  let%bind () = Ws_frame.write writer (Ws_frame.close ~code ()) in
  Pipe.close outbound_writer;
  return ()
;;

let writer_loop ~outbound_pipe writer =
  Pipe.iter outbound_pipe ~f:(fun payload ->
    if Writer.is_closed writer
    then return ()
    else Ws_frame.write writer (Ws_frame.text payload))
;;

let rec receive_loop ~session ~reader ~writer ~outbound_writer ~started =
  let continue () = receive_loop ~session ~reader ~writer ~outbound_writer ~started in
  let protocol_close () =
    close_session writer ~outbound_writer ~code:close_protocol_error
  in
  match%bind Ws_frame.read reader with
  | `Eof ->
    Pipe.close outbound_writer;
    return ()
  | `Error _ ->
    (* Framing-level protocol violation (unmasked / oversized control / fragmented). RFC
       6455 → close 1002. *)
    protocol_close ()
  | `Ok frame ->
    (match frame.opcode with
     | Ws_frame.Text when not !started ->
       (match read_start_message frame with
        | Ok () ->
          started := true;
          continue ()
        | Error _ -> protocol_close ())
     | Ws_frame.Text -> protocol_close ()
     | Ws_frame.Binary when not !started -> protocol_close ()
     | Ws_frame.Binary ->
       (match Session.on_binary session frame.payload with
        | Session.Continue -> continue ()
        | Session.Close { code; reason = _ } ->
          close_session writer ~outbound_writer ~code)
     | Ws_frame.Ping ->
       let%bind () = Ws_frame.write writer (Ws_frame.pong frame.payload) in
       continue ()
     | Ws_frame.Close -> close_session writer ~outbound_writer ~code:1000
     | Ws_frame.Pong -> continue ()
     | Ws_frame.Continuation | Ws_frame.Other _ ->
       (* We never negotiate fragmentation or extension opcodes. *)
       protocol_close ())
;;

let run_session ~config ~inference ~reader ~writer =
  let outbound_reader, outbound_writer = Pipe.create () in
  let session = Session.create ~config ~inference ~outbound:outbound_writer in
  let writer_done = writer_loop ~outbound_pipe:outbound_reader writer in
  let flush_done = Session.run_flush_loop session in
  let started = ref false in
  let recv_done = receive_loop ~session ~reader ~writer ~outbound_writer ~started in
  Deferred.all_unit [ recv_done; writer_done; flush_done ]
;;

(* --- HTTP/1.1 request parsing (server side). Only what's needed for the WebSocket
   upgrade and the /health probe. --- *)

let read_headers reader =
  let rec loop acc =
    match%bind Reader.read_line reader with
    | `Eof -> return (List.rev acc)
    | `Ok "" -> return (List.rev acc)
    | `Ok line ->
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> loop ((String.lowercase (String.strip k), String.strip v) :: acc)
       | None -> loop acc)
  in
  loop []
;;

let parse_request_line line =
  match String.split line ~on:' ' with
  | [ meth; path; _version ] -> Some (meth, path)
  | _ -> None
;;

type request =
  { meth : string
  ; path : string
  ; headers : (string * string) list
  }

let read_request reader =
  match%bind Reader.read_line reader with
  | `Eof -> return None
  | `Ok request_line ->
    (match parse_request_line request_line with
     | None -> return None
     | Some (meth, path) ->
       let%map headers = read_headers reader in
       Some { meth; path; headers })
;;

(* [read_headers] already lowercases keys, so a plain assoc lookup on the lowercased key
   is sufficient. *)
let header_lookup headers k =
  List.Assoc.find headers ~equal:String.equal (String.lowercase k)
;;

let ws_accept_for ~key =
  let digest = Sha1.digest_string (key ^ ws_magic) in
  Base64.encode digest
;;

let write_upgrade_response writer ~ws_key =
  let accept = ws_accept_for ~key:ws_key in
  Writer.write
    writer
    (sprintf
       "HTTP/1.1 101 Switching Protocols\r\n\
        Upgrade: websocket\r\n\
        Connection: Upgrade\r\n\
        Sec-WebSocket-Accept: %s\r\n\
        \r\n"
       accept);
  Writer.flushed writer
;;

let write_simple writer ~status_code ~status_text ~body =
  Writer.write
    writer
    (sprintf
       "HTTP/1.1 %d %s\r\n\
        Content-Length: %d\r\n\
        Content-Type: text/plain\r\n\
        Connection: close\r\n\
        \r\n\
        %s"
       status_code
       status_text
       (String.length body)
       body);
  Writer.flushed writer
;;

let header_eq_ci headers k expected =
  match header_lookup headers k with
  | Some v -> String.Caseless.equal (String.strip v) expected
  | None -> false
;;

(* RFC 6455 §4.2.1: a valid upgrade is GET, Upgrade: websocket, Connection containing
   "upgrade", Sec-WebSocket-Version: 13, and a Sec-WebSocket-Key. Returns the key so the
   caller doesn't re-look-it-up. We don't validate the key is 16 random bytes (loadgen's
   is), just reject obviously-malformed upgrades instead of trusting the key alone. *)
let ws_upgrade_key req =
  let connection_has_upgrade =
    match header_lookup req.headers "connection" with
    | Some c -> String.is_substring (String.lowercase c) ~substring:"upgrade"
    | None -> false
  in
  if String.Caseless.equal req.meth "GET"
     && header_eq_ci req.headers "upgrade" "websocket"
     && connection_has_upgrade
     && header_eq_ci req.headers "sec-websocket-version" "13"
  then header_lookup req.headers "sec-websocket-key"
  else None
;;

let serve ~config ~inference _addr reader writer =
  match%bind read_request reader with
  | None -> return ()
  | Some req ->
    (match req.path with
     | "/ws/stt" ->
       (match ws_upgrade_key req with
        | None ->
          write_simple
            writer
            ~status_code:400
            ~status_text:"Bad Request"
            ~body:"invalid websocket upgrade"
        | Some ws_key ->
          let%bind () = write_upgrade_response writer ~ws_key in
          run_session ~config ~inference ~reader ~writer)
     | "/health" -> write_simple writer ~status_code:200 ~status_text:"OK" ~body:"ok"
     | _ ->
       write_simple writer ~status_code:404 ~status_text:"Not Found" ~body:"not found")
;;

let start (config : Config.t) =
  let inference = Inference.create config in
  Log.Global.info "stt-ocaml-oxcaml starting: %s" (Config.to_string_hum config);
  let where_to_listen = Tcp.Where_to_listen.of_port config.port in
  let%bind _server =
    (* Capacity tuning for the connection-burst at session ramp-up. Async defaults
       ([backlog=64], [max_accepts_per_batch=1]) stall the accept rate under
       hundreds/thousands of near-simultaneous client connects, surfacing as loadgen
       "connect" errors. This is the OCaml analogue of the per-gateway transport tuning
       the README documents (e.g. Rust INFERENCE_HTTP_CLIENTS). [max_connections] defaults
       to ~10k which is well above any 1-vCPU session count. *)
    Tcp.Server.create
      ~backlog:8192
      ~max_accepts_per_batch:64
      ~on_handler_error:`Ignore
      where_to_listen
      (fun addr reader writer -> serve ~config ~inference addr reader writer)
  in
  Deferred.never ()
;;
