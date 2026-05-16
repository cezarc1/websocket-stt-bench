open! Core
open! Async
module Frame = Websocket_async.Frame

let close_protocol_error = 1002

let read_start_message (frame : Frame.t) =
  match frame.Frame.opcode with
  | Frame.Opcode.Text ->
    (match Yojson.Safe.from_string frame.Frame.content with
     | exception _ -> Error "first frame: invalid JSON"
     | json ->
       (match Protocol.Start_message.of_yojson json with
        | Ok msg when String.equal msg.type_ "start" -> Ok ()
        | Ok _ -> Error "first frame: type must equal \"start\""
        | Error e -> Error e))
  | Frame.Opcode.Continuation
  | Frame.Opcode.Binary
  | Frame.Opcode.Close
  | Frame.Opcode.Ping
  | Frame.Opcode.Pong
  | Frame.Opcode.Ctrl _
  | Frame.Opcode.Nonctrl _ -> Error "first frame: expected text JSON"
;;

let close_session ws_out ~code =
  let%bind () = Pipe.write_if_open ws_out (Frame.close code) in
  Pipe.close ws_out;
  return ()
;;

let writer_loop ~outbound_pipe ws_out =
  Pipe.iter outbound_pipe ~f:(fun payload ->
    Pipe.write_if_open ws_out (Frame.create ~opcode:Frame.Opcode.Text ~content:payload ()))
;;

let rec receive_loop ~session ~ws_in ~ws_out ~outbound_writer ~started =
  let continue () = receive_loop ~session ~ws_in ~ws_out ~outbound_writer ~started in
  let protocol_close () =
    Pipe.close outbound_writer;
    close_session ws_out ~code:close_protocol_error
  in
  match%bind Pipe.read ws_in with
  | `Eof ->
    Pipe.close outbound_writer;
    return ()
  | `Ok frame ->
    (match frame.Frame.opcode with
     | Frame.Opcode.Text when not !started ->
       (match read_start_message frame with
        | Ok () ->
          started := true;
          continue ()
        | Error _ -> protocol_close ())
     | Frame.Opcode.Text -> protocol_close ()
     | Frame.Opcode.Binary when not !started -> protocol_close ()
     | Frame.Opcode.Binary ->
       (match Session.on_binary session frame.Frame.content with
        | Session.Continue -> continue ()
        | Session.Close { code; reason = _ } ->
          Pipe.close outbound_writer;
          close_session ws_out ~code)
     | Frame.Opcode.Ping ->
       let%bind () =
         Pipe.write_if_open
           ws_out
           (Frame.create ~opcode:Frame.Opcode.Pong ~content:frame.Frame.content ())
       in
       continue ()
     | Frame.Opcode.Close ->
       Pipe.close outbound_writer;
       close_session ws_out ~code:1000
     | Frame.Opcode.Pong -> continue ()
     | Frame.Opcode.Continuation | Frame.Opcode.Ctrl _ | Frame.Opcode.Nonctrl _ ->
       (* The benchmark protocol never negotiates fragmentation or extension opcodes. *)
       protocol_close ())
;;

let run ~config ~inference ~ws_in ~ws_out =
  let outbound_reader, outbound_writer = Pipe.create () in
  let session = Session.create ~config ~inference ~outbound:outbound_writer in
  let writer_done = writer_loop ~outbound_pipe:outbound_reader ws_out in
  let flush_done = Session.run_flush_loop session in
  let started = ref false in
  let recv_done = receive_loop ~session ~ws_in ~ws_out ~outbound_writer ~started in
  Deferred.all_unit [ recv_done; writer_done; flush_done ]
;;
