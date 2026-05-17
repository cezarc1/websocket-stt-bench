open! Core
open! Async

let ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
let accept_key ~key = Base64.encode (Sha1.digest_string (key ^ ws_magic))

let header_eq_ci headers k expected =
  match Http1.find headers k with
  | Some v -> String.Caseless.equal (String.strip v) expected
  | None -> false
;;

let header_token_ci headers k expected =
  match Http1.find headers k with
  | None -> false
  | Some value ->
    String.split value ~on:','
    |> List.exists ~f:(fun token -> String.Caseless.equal (String.strip token) expected)
;;

let upgrade_key (req : Http1.request) =
  if
    String.Caseless.equal req.meth "GET"
    && String.equal req.version "HTTP/1.1"
    && header_eq_ci req.headers "upgrade" "websocket"
    && header_token_ci req.headers "connection" "upgrade"
    && header_eq_ci req.headers "sec-websocket-version" "13"
  then Http1.find req.headers "sec-websocket-key"
  else None
;;

let write_upgrade_response writer ~ws_key =
  Writer.write
    writer
    (sprintf
       "HTTP/1.1 101 Switching Protocols\r\n\
        Upgrade: websocket\r\n\
        Connection: Upgrade\r\n\
        Sec-WebSocket-Accept: %s\r\n\
        \r\n"
       (accept_key ~key:ws_key));
  Writer.flushed writer
;;
