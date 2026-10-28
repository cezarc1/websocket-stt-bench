open! Core
open! Async

let close_protocol_error = 1002

let read_start_message (frame : Websocket_frame.t) =
  match frame.opcode with
  | Websocket_frame.Text ->
    (match Yojson.Safe.from_string frame.payload with
     | exception _ -> Error "first frame: invalid JSON"
     | json ->
       (match Protocol.Start_message.of_yojson json with
        | Ok msg when String.equal msg.type_ "start" -> Ok ()
        | Ok _ -> Error "first frame: type must equal \"start\""
        | Error e -> Error e))
  | Websocket_frame.Continuation
  | Websocket_frame.Binary
  | Websocket_frame.Close
  | Websocket_frame.Ping
  | Websocket_frame.Pong
  | Websocket_frame.Other _ -> Error "first frame: expected text JSON"
;;

let close_message_too_big = 1009

(* Upper bound on a reassembled fragmented message. The protocol's largest legitimate
   message is a 640-byte PCM frame; this only stops unbounded fragment accumulation. *)
let max_message_bytes = 1 lsl 20

(* A data message whose first frame had FIN=0, awaiting [Continuation] frames. *)
type fragmented =
  { message_opcode : Websocket_frame.opcode
  ; mutable parts : string list (* newest-first *)
  ; mutable len : int
  }

let close_session writer ~outbound_writer ~code =
  (* Close the outbound pipe first so the writer loop drops any queued partial instead of
     writing a data frame after our Close (RFC 6455 §5.5.1). *)
  Pipe.close outbound_writer;
  Websocket_frame.write writer (Websocket_frame.close ~code ())
;;

let writer_loop ~outbound_pipe writer =
  Pipe.iter outbound_pipe ~f:(fun payload ->
    if Writer.is_closed writer || Pipe.is_closed outbound_pipe
    then return ()
    else Websocket_frame.write writer (Websocket_frame.text payload))
;;

(* [receive_loop] reads one frame and handles fragmentation; [dispatch] acts on one
   complete (possibly reassembled) message or control frame. Mutually recursive top-level
   functions so the per-frame path allocates no more closures than before reassembly. *)
let rec receive_loop ~session ~reader ~writer ~outbound_writer ~started ~fragments =
  match%bind Websocket_frame.read reader with
  | `Eof ->
    Pipe.close outbound_writer;
    return ()
  | `Error _ ->
    (* Framing-level protocol violation (unmasked / RSV bits / bad length / oversized or
       fragmented control). RFC 6455 → close 1002. *)
    close_session writer ~outbound_writer ~code:close_protocol_error
  | `Ok frame ->
    (* RFC 6455 §5.4: data messages may be fragmented; control frames (always FIN=1,
       enforced by [Websocket_frame.read]) may be interleaved between fragments. *)
    (match frame.opcode, !fragments with
     | (Websocket_frame.Text | Websocket_frame.Binary), Some _ ->
       (* A new data message before the fragmented one finished. *)
       close_session writer ~outbound_writer ~code:close_protocol_error
     | (Websocket_frame.Text | Websocket_frame.Binary), None when not frame.fin ->
       fragments
       := Some
            { message_opcode = frame.opcode
            ; parts = [ frame.payload ]
            ; len = String.length frame.payload
            };
       receive_loop ~session ~reader ~writer ~outbound_writer ~started ~fragments
     | Websocket_frame.Continuation, None ->
       close_session writer ~outbound_writer ~code:close_protocol_error
     | Websocket_frame.Continuation, Some f ->
       f.parts <- frame.payload :: f.parts;
       f.len <- f.len + String.length frame.payload;
       if f.len > max_message_bytes
       then close_session writer ~outbound_writer ~code:close_message_too_big
       else if not frame.fin
       then receive_loop ~session ~reader ~writer ~outbound_writer ~started ~fragments
       else (
         fragments := None;
         dispatch
           ~session
           ~reader
           ~writer
           ~outbound_writer
           ~started
           ~fragments
           { Websocket_frame.fin = true
           ; opcode = f.message_opcode
           ; payload = String.concat (List.rev f.parts)
           })
     | ( ( Websocket_frame.Text
         | Websocket_frame.Binary
         | Websocket_frame.Close
         | Websocket_frame.Ping
         | Websocket_frame.Pong
         | Websocket_frame.Other _ )
       , _ ) ->
       dispatch ~session ~reader ~writer ~outbound_writer ~started ~fragments frame)

and dispatch
  ~session
  ~reader
  ~writer
  ~outbound_writer
  ~started
  ~fragments
  (frame : Websocket_frame.t)
  =
  let continue () =
    receive_loop ~session ~reader ~writer ~outbound_writer ~started ~fragments
  in
  let protocol_close () =
    close_session writer ~outbound_writer ~code:close_protocol_error
  in
  match frame.opcode with
  | Websocket_frame.Text when not !started ->
    (match read_start_message frame with
     | Ok () ->
       started := true;
       continue ()
     | Error _ -> protocol_close ())
  | Websocket_frame.Text -> protocol_close ()
  | Websocket_frame.Binary when not !started -> protocol_close ()
  | Websocket_frame.Binary ->
    (match Session.on_binary session frame.payload with
     | Session.Continue -> continue ()
     | Session.Close { code; reason = _ } -> close_session writer ~outbound_writer ~code)
  | Websocket_frame.Ping ->
    let%bind () = Websocket_frame.write writer (Websocket_frame.pong frame.payload) in
    continue ()
  | Websocket_frame.Close ->
    if Websocket_frame.valid_close_payload frame.payload
    then close_session writer ~outbound_writer ~code:1000
    else protocol_close ()
  | Websocket_frame.Pong -> continue ()
  | Websocket_frame.Continuation | Websocket_frame.Other _ ->
    (* Extension opcodes are never negotiated. (A Continuation never reaches here:
       [receive_loop] consumes it.) *)
    protocol_close ()
;;

let run ~config ~inference ~diagnostics ~reader ~writer =
  let session_id = Diagnostics.record_session_opened diagnostics in
  let outbound_reader, outbound_writer = Pipe.create () in
  let session =
    Session.create ~config ~inference ~diagnostics ~session_id ~outbound:outbound_writer
  in
  let writer_done = writer_loop ~outbound_pipe:outbound_reader writer in
  let flush_done = Session.run_flush_loop session in
  let started = ref false in
  let fragments = ref None in
  (* If the receive loop raises (e.g. Tcp.Server closed the fds after the peer vanished),
     still close the outbound pipe: that is what stops the flush loop and releases the
     session's inference connection. *)
  let recv_done =
    Monitor.protect
      ~finally:(fun () ->
        Pipe.close outbound_writer;
        return ())
      (fun () ->
        receive_loop ~session ~reader ~writer ~outbound_writer ~started ~fragments)
  in
  let%map () = Deferred.all_unit [ recv_done; writer_done; flush_done ] in
  Diagnostics.record_session_closed diagnostics ~session_id
;;
