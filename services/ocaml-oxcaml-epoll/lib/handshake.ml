let websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
let accept_key key = Base64.encode (Sha1.digest_string (key ^ websocket_guid))
