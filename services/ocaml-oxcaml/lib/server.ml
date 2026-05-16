open! Core
open! Async

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

let serve ~config ~inference _addr reader writer =
  match%bind Http1.read_request reader with
  | None -> return ()
  | Some req ->
    (match req.path with
     | "/ws/stt" ->
       (match Websocket_handshake.upgrade_key req with
        | None ->
          write_simple
            writer
            ~status_code:400
            ~status_text:"Bad Request"
            ~body:"invalid websocket upgrade"
        | Some ws_key ->
          let%bind () = Websocket_handshake.write_upgrade_response writer ~ws_key in
          Websocket_connection.run ~config ~inference ~reader ~writer)
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
