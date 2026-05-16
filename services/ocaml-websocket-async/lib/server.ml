open! Core
open! Async

let header_token_contains headers name token =
  match Cohttp.Header.get headers name with
  | None -> false
  | Some value ->
    String.split value ~on:','
    |> List.exists ~f:(fun part ->
      String.equal (String.lowercase (String.strip part)) (String.lowercase token))
;;

let websocket_upgrade_request req =
  let headers = Cohttp.Request.headers req in
  match Cohttp.Request.meth req, Cohttp.Request.version req with
  | `GET, `HTTP_1_1 ->
    header_token_contains headers "connection" "upgrade"
    && (match Cohttp.Header.get headers "upgrade" with
        | Some value -> String.equal (String.lowercase value) "websocket"
        | None -> false)
    && (match Cohttp.Header.get headers "sec-websocket-version" with
        | Some version -> String.equal version "13"
        | None -> false)
    && Option.is_some (Cohttp.Header.get headers "sec-websocket-key")
  | _ -> false
;;

let respond_string ?(status = `OK) body =
  let headers = Cohttp.Header.init_with "content-type" "text/plain" in
  let%map response = Cohttp_async.Server.respond_string ~headers ~status body in
  `Response response
;;

let websocket_response ~config ~inference req =
  if not (websocket_upgrade_request req)
  then respond_string ~status:`Bad_request "invalid websocket upgrade"
  else (
    let app_to_ws, ws_out = Pipe.create () in
    let ws_in, ws_to_app = Pipe.create () in
    let response, handler =
      Websocket_async.upgrade_connection
        ~ping_interval:Time_ns.Span.zero
        ~app_to_ws
        ~ws_to_app
        ~f:(fun () -> Websocket_connection.run ~config ~inference ~ws_in ~ws_out)
        req
    in
    return (`Expert (response, handler)))
;;

let serve ~config ~inference ~body:_ _addr req =
  match Uri.path (Cohttp.Request.uri req) with
  | "/health" -> respond_string "ok"
  | "/ws/stt" -> websocket_response ~config ~inference req
  | _ -> respond_string ~status:`Not_found "not found"
;;

let start (config : Config.t) =
  let inference = Inference.create config in
  Log.Global.info "stt-ocaml-websocket-async starting: %s" (Config.to_string_hum config);
  let where_to_listen = Tcp.Where_to_listen.of_port config.port in
  let%bind _server =
    Cohttp_async.Server.create_expert
      ~backlog:8192
      ~on_handler_error:`Ignore
      where_to_listen
      (serve ~config ~inference)
  in
  Deferred.never ()
;;
