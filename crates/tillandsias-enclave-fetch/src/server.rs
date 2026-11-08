//! MCP over HTTP (JSON responses to POSTed JSON-RPC, the non-streaming form of
//! the streamable-HTTP transport) and the tools: `catalog`, `fetch`, `feed`,
//! `docs`. Every tool call writes one JSONL audit record: client, tool, URL,
//! bytes, verdict.
//!
//! @trace spec:proxy-container, order:2041-csm4

use crate::catalog::Kind;
use crate::fetch::{Fetcher, Refusal};
use crate::markdown;
use serde_json::{Value, json};
use std::io::Write;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub const PAGE_CHARS: usize = 20_000;
const MAX_HEADER: usize = 16 * 1024;
const MAX_REQUEST: usize = 64 * 1024;
const PROTOCOL: &str = "2025-06-18";

pub type Audit = Arc<Mutex<Box<dyn Write + Send>>>;

pub fn audit(sink: &Audit, client: &str, tool: &str, url: &str, bytes: usize, verdict: &str) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = json!({"ts": ts, "client": client, "tool": tool, "url": url, "bytes": bytes, "verdict": verdict});
    if let Ok(mut w) = sink.lock() {
        let _ = writeln!(w, "{line}");
        let _ = w.flush();
    }
}

fn tools() -> Value {
    json!([
        {"name": "catalog", "description": "List the curated sources this service may fetch: docs libraries, feeds and pages, each with its reason.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "fetch", "description": "Fetch a URL covered by the catalog and return it as Markdown, 20000 characters per page.",
         "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}, "page": {"type": "integer", "minimum": 1}}, "required": ["url"]}},
        {"name": "feed", "description": "Read a catalog RSS/Atom feed by name as a Markdown list of entries.",
         "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}, "required": ["name"]}},
        {"name": "docs", "description": "Read a catalog documentation library by name; with a query, use the library's own search when it has one.",
         "inputSchema": {"type": "object", "properties": {"library": {"type": "string"}, "query": {"type": "string"}, "page": {"type": "integer", "minimum": 1}}, "required": ["library"]}}
    ])
}

fn text_result(text: String, is_error: bool) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": is_error})
}

fn page_of(arg: &Value) -> usize {
    arg.get("page").and_then(Value::as_u64).unwrap_or(1) as usize
}

async fn fetch_md(f: &Fetcher, url: &str, page: usize) -> Result<(String, usize), Refusal> {
    let got = f.get(url).await?;
    let md = if got.content_type.contains("html") {
        markdown::html_to_markdown(&got.body)
    } else {
        got.body
    };
    let (text, total) = markdown::page(&md, page, PAGE_CHARS);
    let head = format!(
        "Source: {} (page {}/{})\n\n",
        got.final_url,
        page.clamp(1, total),
        total
    );
    let n = text.len();
    Ok((head + &text, n))
}

/// Run one tool. Returns the MCP result and writes the audit record.
pub async fn call(f: &Fetcher, sink: &Audit, client: &str, name: &str, arg: &Value) -> Value {
    let s = |k: &str| arg.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let (url, outcome): (String, Result<(String, usize), Refusal>) = match name {
        "catalog" => {
            let list: Vec<String> = f
                .catalog
                .sources
                .iter()
                .map(|x| format!("- {} ({:?}): {} — {}", x.name, x.kind, x.url, x.reason))
                .collect();
            let t = list.join("\n");
            let n = t.len();
            (String::new(), Ok((t, n)))
        }
        "fetch" => {
            let u = s("url");
            let r = fetch_md(f, &u, page_of(arg)).await;
            (u, r)
        }
        "feed" => match f.catalog.named(&s("name"), Kind::Feed) {
            Some(src) => {
                let u = src.url.clone();
                let limit = arg
                    .get("limit")
                    .and_then(Value::as_u64)
                    .unwrap_or(20)
                    .clamp(1, 100);
                let r = f.get(&u).await.map(|g| {
                    let t = markdown::feed_to_markdown(&g.body, limit as usize);
                    let n = t.len();
                    (t, n)
                });
                (u, r)
            }
            None => (
                s("name"),
                Err(Refusal::NotInCatalog(format!("feed {}", s("name")))),
            ),
        },
        "docs" => match f.catalog.named(&s("library"), Kind::Docs) {
            Some(src) => {
                let q = s("query");
                let u = match (&src.search, q.is_empty()) {
                    (Some(t), false) => t.replace(
                        "{query}",
                        &url::form_urlencoded::byte_serialize(q.as_bytes()).collect::<String>(),
                    ),
                    _ => src.url.clone(),
                };
                let r = fetch_md(f, &u, page_of(arg)).await;
                (u, r)
            }
            None => (
                s("library"),
                Err(Refusal::NotInCatalog(format!(
                    "docs library {}",
                    s("library")
                ))),
            ),
        },
        other => {
            audit(sink, client, other, "", 0, "unknown-tool");
            return text_result(format!("unknown tool {other}"), true);
        }
    };
    match outcome {
        Ok((text, n)) => {
            audit(sink, client, name, &url, n, "ok");
            text_result(text, false)
        }
        Err(e) => {
            audit(sink, client, name, &url, 0, e.kind());
            text_result(e.to_string(), true)
        }
    }
}

/// Handle one JSON-RPC message. `None` for a notification.
pub async fn handle(f: &Fetcher, sink: &Audit, client: &str, msg: &Value) -> Option<Value> {
    let id = msg.get("id").cloned()?;
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(json!({}));
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "enclave-fetch", "version": env!("CARGO_PKG_VERSION")}
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools()})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let arg = params.get("arguments").cloned().unwrap_or(json!({}));
            Ok(call(f, sink, client, name, &arg).await)
        }
        _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
    };
    Some(match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
    })
}

fn response(status: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

/// Serve MCP on `listener` until the process ends. One request per connection.
pub async fn serve(listener: TcpListener, f: Arc<Fetcher>, sink: Audit) -> std::io::Result<()> {
    loop {
        let (mut sock, peer) = listener.accept().await?;
        let f = f.clone();
        let sink = sink.clone();
        tokio::spawn(async move {
            let client = peer.ip().to_string();
            let reply = match read_request(&mut sock).await {
                Ok((method, path, body)) => route(&f, &sink, &client, &method, &path, &body).await,
                Err(status) => response(status, "{}"),
            };
            let _ = sock.write_all(reply.as_bytes()).await;
            let _ = sock.shutdown().await;
        });
    }
}

async fn route(
    f: &Fetcher,
    sink: &Audit,
    client: &str,
    method: &str,
    path: &str,
    body: &[u8],
) -> String {
    match (method, path) {
        ("GET", "/health") => response("200 OK", "{\"ok\":true}"),
        ("POST", "/mcp") => {
            let Ok(msg) = serde_json::from_slice::<Value>(body) else {
                return response(
                    "400 Bad Request",
                    &json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}).to_string(),
                );
            };
            match handle(f, sink, client, &msg).await {
                Some(v) => response("200 OK", &v.to_string()),
                None => {
                    "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into()
                }
            }
        }
        ("GET", "/mcp") => response("405 Method Not Allowed", "{}"),
        _ => response("404 Not Found", "{}"),
    }
}

async fn read_request<S: AsyncReadExt + Unpin>(
    sock: &mut S,
) -> Result<(String, String, Vec<u8>), &'static str> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let head_end = loop {
        let n = sock.read(&mut tmp).await.map_err(|_| "400 Bad Request")?;
        if n == 0 {
            return Err("400 Bad Request");
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        if buf.len() > MAX_HEADER {
            return Err("431 Request Header Fields Too Large");
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let method = first.next().unwrap_or("").to_string();
    let path = first
        .next()
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("")
        .to_string();
    let len = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
        .unwrap_or(0);
    if len > MAX_REQUEST {
        return Err("413 Payload Too Large");
    }
    let mut body = buf[head_end + 4..].to_vec();
    while body.len() < len {
        let n = sock.read(&mut tmp).await.map_err(|_| "400 Bad Request")?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(len);
    Ok((method, path, body))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::Catalog;

    struct Shared(Arc<Mutex<Vec<u8>>>);
    impl Write for Shared {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn setup() -> (Fetcher, Audit, Arc<Mutex<Vec<u8>>>) {
        let cat =
            Catalog::parse(include_str!("../../../images/enclave-fetch/catalog.yaml")).unwrap();
        let mut f = Fetcher::new(cat, None);
        f.resolve_override.insert(
            "doc.rust-lang.org".into(),
            vec!["10.0.0.9:443".parse().unwrap()],
        );
        let log = Arc::new(Mutex::new(Vec::new()));
        let sink: Audit = Arc::new(Mutex::new(Box::new(Shared(log.clone()))));
        (f, sink, log)
    }

    #[tokio::test]
    async fn lists_tools_and_initializes() {
        let (f, sink, _) = setup();
        let r = handle(
            &f,
            &sink,
            "c",
            &json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
        )
        .await
        .unwrap();
        let names: Vec<&str> = r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["catalog", "fetch", "feed", "docs"]);
        let r = handle(&f, &sink, "c", &json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-03-26"}})).await.unwrap();
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert!(
            handle(
                &f,
                &sink,
                "c",
                &json!({"jsonrpc":"2.0","method":"notifications/initialized"})
            )
            .await
            .is_none()
        );
    }

    #[tokio::test]
    async fn refusals_are_tool_errors_and_audited() {
        let (f, sink, log) = setup();
        let r = call(
            &f,
            &sink,
            "10.0.42.7",
            "fetch",
            &json!({"url": "https://evil.example/"}),
        )
        .await;
        assert_eq!(r["isError"], true);
        assert!(
            r["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("not in the enclave-fetch catalog")
        );
        let r = call(
            &f,
            &sink,
            "10.0.42.7",
            "docs",
            &json!({"library": "rust-std", "query": "Vec"}),
        )
        .await;
        assert_eq!(r["isError"], true);
        let r = call(&f, &sink, "10.0.42.7", "feed", &json!({"name": "nope"})).await;
        assert_eq!(r["isError"], true);
        let lines: Vec<Value> = String::from_utf8(log.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0]["verdict"], "not-in-catalog");
        assert_eq!(lines[1]["verdict"], "non-public-address");
        assert_eq!(lines[1]["url"], "https://doc.rust-lang.org/std/?search=Vec");
        assert_eq!(lines[1]["client"], "10.0.42.7");
        assert_eq!(lines[2]["verdict"], "not-in-catalog");
    }

    #[tokio::test]
    async fn http_round_trip() {
        let (f, sink, _) = setup();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(serve(listener, Arc::new(f), sink));
        let body = r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"catalog","arguments":{}}}"#;
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(format!("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).await.unwrap();
        assert!(out.starts_with("HTTP/1.1 200 OK"), "{out}");
        assert!(out.contains("rust-std"), "{out}");
    }
}
