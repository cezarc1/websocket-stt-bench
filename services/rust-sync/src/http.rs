//! Non-blocking HTTP/1.1 upgrade handshake for an incoming connection.
//!
//! Bytes may arrive across several epoll readable events, so the request
//! head accumulates in a per-connection buffer until the blank-line
//! terminator. A WebSocket client must wait for the 101 before sending
//! frames, so reading the head in bulk can't swallow frame bytes.

use std::io::{self, Read, Write};

use mio::net::TcpStream;
use tungstenite::handshake::derive_accept_key;

const MAX_HEADER_BYTES: usize = 16 * 1024;

pub enum Route {
    /// Head complete, valid `GET /ws/stt` upgrade; the 101 was written and
    /// the socket is ready for `WebSocket::from_raw_socket`.
    WebSocket,
    /// Head complete but not an upgrade (`/health` 200, 404, …); a
    /// response was written and the caller should drop the connection.
    Handled,
    /// Head not yet fully received; call again on the next readable event.
    NeedMore,
}

/// Drain the socket into `buf`, and once the head is complete route it.
pub fn feed(stream: &mut TcpStream, buf: &mut Vec<u8>) -> io::Result<Route> {
    let mut chunk = [0u8; 1024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => return Err(io::Error::from(io::ErrorKind::UnexpectedEof)),
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() > MAX_HEADER_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "request head too large",
                    ));
                }
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }

    let Some(end) = find_double_crlf(buf) else {
        return Ok(Route::NeedMore);
    };
    let head = std::str::from_utf8(&buf[..end])
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
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
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.write_all(body);
            Ok(Route::Handled)
        }
        "/ws/stt" => {
            let Some(key) = header(&lines, "sec-websocket-key") else {
                write_simple(stream, 400, "Bad Request")?;
                return Ok(Route::Handled);
            };
            let accept = derive_accept_key(key.as_bytes());
            let resp = format!(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            );
            stream.write_all(resp.as_bytes())?;
            Ok(Route::WebSocket)
        }
        _ => {
            write_simple(stream, 404, "Not Found")?;
            Ok(Route::Handled)
        }
    }
}

fn write_simple(stream: &mut TcpStream, code: u16, reason: &str) -> io::Result<()> {
    let _ = stream.write_all(
        format!("HTTP/1.1 {code} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .as_bytes(),
    );
    Ok(())
}

fn header<'a>(lines: &'a std::str::Split<'a, &str>, name: &str) -> Option<&'a str> {
    lines.clone().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        k.trim().eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}
