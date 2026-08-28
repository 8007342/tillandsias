//! openai-stub — litmus fixture endpoint for the expert-serve tests.
//!
//! @trace spec:expert-serve-grounded-pipeline
//! @trace order:920-pxg6
//!
//! A deterministic OpenAI-compatible stub the litmus-expert-serve-* fixtures
//! bind where a model endpoint would be. Behavior, all of it:
//!
//!   * every request's `METHOD PATH` line is APPENDED to `--log` — the
//!     request log is the litmus's proof surface ("no raw-model request"
//!     means this file stays empty of /chat/completions lines);
//!   * `POST .../embeddings`      → a fixed `[1.0, 0.0]` embedding, so a
//!     fixture index whose vectors are `[1.0, 0.0]` retrieves at cosine 1;
//!   * `POST .../chat/completions` → `choices[0].message.content` is the
//!     verbatim text of `--content <file>`, re-read per request so one stub
//!     serves multiple scripted answers;
//!   * anything else             → 404.
//!
//! Std + serde_json only; single-threaded; serves until killed.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

fn read_request(stream: &mut TcpStream) -> Option<String> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];
    let header_end = loop {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > 1 << 20 {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let content_length: usize = head
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            if k.eq_ignore_ascii_case("content-length") {
                v.trim().parse().ok()
            } else {
                None
            }
        })
        .unwrap_or(0);
    while buf.len() < header_end + content_length {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    head.lines().next().map(str::to_string)
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 0;
    let mut log: Option<String> = None;
    let mut content: Option<String> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--port" => port = args.next().and_then(|v| v.parse().ok()).unwrap_or(0),
            "--log" => log = args.next(),
            "--content" => content = args.next(),
            other => {
                eprintln!("openai-stub: unknown arg {other}");
                std::process::exit(2);
            }
        }
    }
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|e| {
        eprintln!("openai-stub: bind 127.0.0.1:{port}: {e}");
        std::process::exit(1);
    });
    // The pinned readiness line litmus fixtures wait for.
    eprintln!(
        "openai-stub: listening on 127.0.0.1:{}",
        listener.local_addr().map(|a| a.port()).unwrap_or(port)
    );
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let Some(request_line) = read_request(&mut stream) else {
            continue;
        };
        if let Some(path) = &log
            && let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
        {
            let _ = writeln!(f, "{request_line}");
        }
        if request_line.contains("/embeddings") {
            respond(
                &mut stream,
                "200 OK",
                r#"{"data":[{"embedding":[1.0,0.0]}]}"#,
            );
        } else if request_line.contains("/chat/completions") {
            let text = content
                .as_deref()
                .and_then(|p| std::fs::read_to_string(p).ok())
                .unwrap_or_default();
            let body = serde_json::json!({
                "choices": [{"message": {"role": "assistant", "content": text.trim()}}]
            });
            respond(&mut stream, "200 OK", &body.to_string());
        } else {
            respond(&mut stream, "404 Not Found", r#"{"error":"no such route"}"#);
        }
    }
}
