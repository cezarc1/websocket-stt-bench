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

let close_session writer ~outbound_writer ~code =
  let%bind () = Websocket_frame.write writer (Websocket_frame.close ~code ()) in
  Pipe.close outbound_writer;
  return ()
;;

let writer_loop ~outbound_pipe writer =
  Pipe.iter outbound_pipe ~f:(fun payload ->
    if Writer.is_closed writer
    then return ()
    else Websocket_frame.write writer (Websocket_frame.text payload))
;;

let rec receive_loop ~session ~reader ~writer ~outbound_writer ~started =
  let continue () = receive_loop ~session ~reader ~writer ~outbound_writer ~started in
  let protocol_close () =
    close_session writer ~outbound_writer ~code:close_protocol_error
  in
  match%bind Websocket_frame.read reader with
  | `Eof ->
    Pipe.close outbound_writer;
    return ()
  | `Error _ -> protocol_close ()
  | `Ok frame ->
    if not frame.fin
    then protocol_close ()
    else (
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
         | Session.Close { code; reason = _ } ->
           close_session writer ~outbound_writer ~code)
      | Websocket_frame.Ping ->
        let%bind () = Websocket_frame.write writer (Websocket_frame.pong frame.payload) in
        continue ()
      | Websocket_frame.Close -> close_session writer ~outbound_writer ~code:1000
      | Websocket_frame.Pong -> continue ()
      | Websocket_frame.Continuation | Websocket_frame.Other _ -> protocol_close ())
;;

let run ~config ~inference ~reader ~writer =
  let outbound_reader, outbound_writer = Pipe.create () in
  let session = Session.create ~config ~inference ~outbound:outbound_writer in
  let writer_done = writer_loop ~outbound_pipe:outbound_reader writer in
  let flush_done = Session.run_flush_loop session in
  let started = ref false in
  let recv_done = receive_loop ~session ~reader ~writer ~outbound_writer ~started in
  Deferred.all_unit [ recv_done; writer_done; flush_done ]
;;
