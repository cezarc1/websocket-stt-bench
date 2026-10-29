open! Core
open! Async

let close_protocol_error = 1002
let close_message_too_big = 1009

(* Upper bound on a reassembled fragmented message. The protocol's largest legitimate
   message is the 640-byte PCM frame; this only stops a never-ending fragment stream from
   growing memory without bound. *)
let max_message_bytes = 64 * 1024

let read_start_message payload =
  match Yojson.Safe.from_string payload with
  | exception _ -> Error "first frame: invalid JSON"
  | json ->
    (match Protocol.Start_message.of_yojson json with
     | Ok msg when String.equal msg.type_ "start" -> Ok ()
     | Ok _ -> Error "first frame: type must equal \"start\""
     | Error e -> Error e)
;;

(* State shared by the receive and writer loops. [close_sent] fences the writer loop: RFC
   6455 §5.5.1 forbids data frames after our Close, but partials can still be queued in
   the outbound pipe when we close. *)
type conn =
  { session : Session.t
  ; reader : Reader.t
  ; writer : Writer.t
  ; outbound_writer : string Pipe.Writer.t
  ; mutable started : bool
  ; mutable close_sent : bool
  ; (* In-progress fragmented message: data opcode, fragments newest-first, total bytes. *)
    mutable fragments : (Websocket_frame.opcode * string list * int) option
  }

let close_session c ~code =
  c.close_sent <- true;
  Pipe.close c.outbound_writer;
  Websocket_frame.write c.writer (Websocket_frame.close ~code ())
;;

let writer_loop ~outbound_pipe c =
  Pipe.iter outbound_pipe ~f:(fun payload ->
    if c.close_sent || Writer.is_closed c.writer
    then return ()
    else Websocket_frame.write c.writer (Websocket_frame.text payload))
;;

(* A complete (possibly reassembled) data message. *)
let on_message c (opcode : Websocket_frame.opcode) payload ~continue =
  match opcode with
  | Text when not c.started ->
    (match read_start_message payload with
     | Ok () ->
       c.started <- true;
       continue ()
     | Error _ -> close_session c ~code:close_protocol_error)
  | Binary when c.started ->
    (match Session.on_binary c.session payload with
     | Session.Continue -> continue ()
     | Session.Close { code; reason = _ } -> close_session c ~code)
  | Text | Binary | Continuation | Close | Ping | Pong | Other _ ->
    close_session c ~code:close_protocol_error
;;

let rec receive_loop c =
  let continue () = receive_loop c in
  let protocol_close () = close_session c ~code:close_protocol_error in
  match%bind Websocket_frame.read c.reader with
  | `Eof ->
    Pipe.close c.outbound_writer;
    return ()
  | `Error _ -> protocol_close ()
  | `Ok frame ->
    (match frame.opcode, c.fragments with
     (* Control frames may be interleaved with a fragmented message (RFC 6455 §5.4);
        [Websocket_frame.read] already rejects fragmented or oversized control frames. *)
     | Ping, _ ->
       let%bind () =
         Websocket_frame.write c.writer (Websocket_frame.pong frame.payload)
       in
       continue ()
     | Pong, _ -> continue ()
     | Close, _ -> close_session c ~code:1000
     | (Text | Binary), None when frame.fin ->
       on_message c frame.opcode frame.payload ~continue
     | (Text | Binary), None ->
       let len = String.length frame.payload in
       if len > max_message_bytes
       then close_session c ~code:close_message_too_big
       else (
         c.fragments <- Some (frame.opcode, [ frame.payload ], len);
         continue ())
     | Continuation, Some (opcode, parts, len) ->
       let len = len + String.length frame.payload in
       if len > max_message_bytes
       then close_session c ~code:close_message_too_big
       else if frame.fin
       then (
         c.fragments <- None;
         on_message c opcode (String.concat (List.rev (frame.payload :: parts))) ~continue)
       else (
         c.fragments <- Some (opcode, frame.payload :: parts, len);
         continue ())
     (* A new data frame mid-message, a continuation with nothing to continue, or a
        reserved opcode. *)
     | (Text | Binary), Some _ | Continuation, None | Other _, _ -> protocol_close ())
;;

let run ~config ~inference ~reader ~writer =
  let outbound_reader, outbound_writer = Pipe.create () in
  let session = Session.create ~config ~inference ~outbound:outbound_writer in
  let c =
    { session
    ; reader
    ; writer
    ; outbound_writer
    ; started = false
    ; close_sent = false
    ; fragments = None
    }
  in
  let writer_done = writer_loop ~outbound_pipe:outbound_reader c in
  (* The flush loop is not awaited: it can be mid-sleep (<= flush interval) or
     mid-inference (<= request timeout) when the socket closes, and holding the TCP
     connection open for that defeats a prompt close. It observes the closed outbound pipe
     on its own, drops any result, and closes its inference connection. *)
  don't_wait_for (Session.run_flush_loop session);
  (* If the receive loop raises (e.g. Tcp.Server closed the fds after the peer vanished),
     still close the outbound pipe: that is what stops the writer and flush loops and
     releases the session's inference connection. *)
  let recv_done =
    Monitor.protect
      ~finally:(fun () ->
        Pipe.close outbound_writer;
        return ())
      (fun () -> receive_loop c)
  in
  Deferred.all_unit [ recv_done; writer_done ]
;;
