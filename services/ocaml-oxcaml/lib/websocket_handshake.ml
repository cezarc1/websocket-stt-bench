open! Core
open! Async

let ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

(* RFC 6455 §1.3: Sec-WebSocket-Accept = base64(sha1(key ^ GUID)). SHA-1/Base64 are
   implementation details of the handshake — nothing else in the gateway needs them. *)
let accept_key ~key = Base64.encode (Sha1.digest_string (key ^ ws_magic))

let header_eq_ci headers k expected =
  match Http1.find headers k with
  | Some v -> String.Caseless.equal (String.strip v) expected
  | None -> false
;;

(* RFC 6455 §4.2.1: a valid upgrade is GET, Upgrade: websocket, Connection containing
   "upgrade", Sec-WebSocket-Version: 13, and a Sec-WebSocket-Key. Returns the key so the
   caller doesn't re-look-it-up. We don't validate the key is 16 random bytes (loadgen's
   is), just reject obviously-malformed upgrades instead of trusting the key alone. *)
let upgrade_key (req : Http1.request) =
  let connection_has_upgrade =
    match Http1.find req.headers "connection" with
    | Some c -> String.is_substring (String.lowercase c) ~substring:"upgrade"
    | None -> false
  in
  if String.Caseless.equal req.meth "GET"
     && header_eq_ci req.headers "upgrade" "websocket"
     && connection_has_upgrade
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
