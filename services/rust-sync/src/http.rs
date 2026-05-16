//! Minimal HTTP/1.1 request read + routing for the connection's first
//! bytes. We parse the request line and headers ourselves (the WS client
//! waits for the 101 before sending frames, so there is nothing pipelined
//! to over-read) and hand the post-handshake socket to tungstenite.

use std::io::{self, Read, Write};
use std::net::TcpStream;

use tungstenite::handshake::derive_accept_key;

const MAX_HEADER_BYTES: usize = 16 * 1024;

pub enum Route {
    /// Valid `GET /ws/stt` upgrade; the 101 response has been written and
    /// the socket is ready for `WebSocket::from_raw_socket`.
    WebSocket,
    /// Anything else: a response has been written and the caller should
    /// drop the connection.
    Handled,
}

/// Read the request head, route it, and (for `/ws/stt`) complete the
/// WebSocket upgrade by writing the 101 response.
pub fn handshake(stream: &mut TcpStream) -> io::Result<Route> {
    let head = read_head(stream)?;
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");

    if method != "GET" {
        write_simple(stream, 405, "Method Not Allowed")?;
        return Ok(Route::Handled);
    }

    match path {
        "/health" => {
            let body = br#"{"ok":true,"runtime":"rust-sync"}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )?;
            stream.write_all(body)?;
            Ok(Route::Handled)
        }
        "/ws/stt" => {
            let Some(key) = header(&lines, "sec-websocket-key") else {
                write_simple(stream, 400, "Bad Request")?;
                return Ok(Route::Handled);
            };
            let accept = derive_accept_key(key.as_bytes());
            write!(
                stream,
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            )?;
            stream.flush()?;
            Ok(Route::WebSocket)
        }
        _ => {
            write_simple(stream, 404, "Not Found")?;
            Ok(Route::Handled)
        }
    }
}

fn write_simple(stream: &mut TcpStream, code: u16, reason: &str) -> io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {code} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
}

/// Case-insensitive header lookup over the already-split header lines.
fn header<'a>(lines: &'a std::str::Split<'a, &str>, name: &str) -> Option<&'a str> {
    lines.clone().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        k.trim().eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

/// Read up to and including the blank-line terminator. One byte per read
/// keeps us from consuming WebSocket frame bytes into a buffer tungstenite
/// can't see; this runs once per connection, off the hot path.
fn read_head(stream: &mut TcpStream) -> io::Result<String> {
    let mut buf = Vec::with_capacity(512);
    let mut byte = [0u8; 1];
    loop {
        let n = stream.read(&mut byte)?;
        if n == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        buf.push(byte[0]);
        if buf.ends_with(b"\r\n\r\n") {
            buf.truncate(buf.len() - 4);
            break;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request head too large",
            ));
        }
    }
    String::from_utf8(buf).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))
}
