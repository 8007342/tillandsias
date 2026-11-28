//! Tests for the Lemonade relay policy (order 2456-lrly).
//!
//! Every test drives [`Relay::serve_connection`] over an in-memory duplex
//! stream, with a STUB upstream on 127.0.0.1 that counts the connections it
//! accepts. "Refused" therefore means two things at once: the guest got the
//! named 403 (or a silent drop, for a bad credential) AND the stub saw zero
//! connections, so no byte reached Lemonade.
//!
//! @trace order:2456-lrly

use super::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const APPROVED: &str = "Qwen3-0.6B-GGUF";
const APPROVED_ASR: &str = "Whisper-Tiny";

struct Stub {
    addr: std::net::SocketAddr,
    accepts: Arc<AtomicUsize>,
    seen: Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
}

/// A stub Lemonade: counts accepts, records each request (head + declared
/// body), answers a fixed 200.
async fn stub_upstream() -> Stub {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let accepts = Arc::new(AtomicUsize::new(0));
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (a, s) = (accepts.clone(), seen.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            a.fetch_add(1, Ordering::SeqCst);
            let s = s.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                loop {
                    let n = match tokio::time::timeout(
                        std::time::Duration::from_millis(500),
                        sock.read(&mut chunk),
                    )
                    .await
                    {
                        Ok(Ok(n)) => n,
                        _ => break,
                    };
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(end) = find(&buf, b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
                        let cl = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .and_then(|v| v.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        if buf.len() >= end + 4 + cl {
                            break;
                        }
                    }
                }
                s.lock().unwrap().push(buf);
                let _ = sock
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                          Content-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}",
                    )
                    .await;
                let _ = sock.shutdown().await;
            });
        }
    });
    Stub {
        addr,
        accepts,
        seen,
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

struct Fixture {
    relay: Arc<Relay>,
    stub: Stub,
    cred: LaneCredential,
}

async fn fixture() -> Fixture {
    let stub = stub_upstream().await;
    let mut config = RelayConfig::tray_default();
    config.upstream = stub.addr;
    let lanes = Arc::new(LaneRegistry::default());
    let cred = lanes.mint("forge-doris-1");
    let catalog = Arc::new(StaticCatalog(vec![
        APPROVED.to_string(),
        APPROVED_ASR.to_string(),
    ]));
    let relay = Arc::new(Relay::new(config, lanes, catalog));
    Fixture { relay, stub, cred }
}

/// Send `raw` (already carrying any preamble) and read the whole reply.
async fn exchange(relay: &Arc<Relay>, raw: Vec<u8>) -> Vec<u8> {
    let (mut client, server) = tokio::io::duplex(64 * 1024 * 1024);
    let relay = relay.clone();
    let task = tokio::spawn(async move { relay.serve_connection(server).await });
    let _ = client.write_all(&raw).await;
    let mut out = Vec::new();
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        client.read_to_end(&mut out),
    )
    .await;
    drop(client);
    let _ = task.await;
    out
}

fn with_preamble(cred: &LaneCredential, http: &[u8]) -> Vec<u8> {
    let mut raw = cred.preamble().into_bytes();
    raw.extend_from_slice(http);
    raw
}

fn post_json(path: &str, body: &str, extra_headers: &str) -> Vec<u8> {
    format!(
        "POST {path} HTTP/1.1\r\nHost: lemonade:13305\r\nContent-Type: application/json\r\n\
         {extra_headers}Content-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

fn status(reply: &[u8]) -> u16 {
    std::str::from_utf8(reply)
        .ok()
        .and_then(|s| s.split(' ').nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0)
}

fn text(reply: &[u8]) -> String {
    String::from_utf8_lossy(reply).into_owned()
}

#[tokio::test]
async fn every_refused_route_is_a_named_403_and_opens_no_upstream_connection() {
    let f = fixture().await;
    let model_body = format!("{{\"model\":\"{APPROVED}\"}}");
    let cases: Vec<(String, String)> = [
        "POST /api/v1/pull",
        "POST /api/v1/load",
        "POST /api/v1/unload",
        "POST /api/v1/delete",
        "POST /api/v1/install",
        "POST /api/v1/params",
        "GET /api/v1/system-info",
        "GET /api/v1/health",
        "GET /api/v1/stats",
        "GET /api/v1/logs",
        "GET /api/v1/downloads",
        "GET /internal/shutdown",
        "POST /api/v1/admin/settings",
        "GET /api/v1/logs/stream",
        "POST /api/v0/chat/completions",
        "POST /v1/chat/completions",
        "GET /",
        // allowlisted path, wrong method
        "GET /api/v1/chat/completions",
        "POST /api/v1/models",
        "DELETE /api/v1/models",
        // traversal and encoding tricks that normalise onto a refused route
        "POST /api/v1/chat/../pull",
        "POST /api/v1/./pull",
        "POST /api/v1%2Fpull",
        "POST /api/v1/chat%2fcompletions",
        "POST /api/v1/chat/completions/../../pull",
        "POST /api/v1/%2e%2e/pull",
        "POST http://127.0.0.1:13306/api/v1/chat/completions",
    ]
    .iter()
    .map(|l| {
        let (m, p) = l.split_once(' ').unwrap();
        (m.to_string(), p.to_string())
    })
    .collect();
    for (method, path) in &cases {
        let http = format!(
            "{method} {path} HTTP/1.1\r\nHost: lemonade:13305\r\nContent-Type: application/json\r\n\
             Content-Length: {}\r\n\r\n{model_body}",
            model_body.len()
        );
        let reply = exchange(&f.relay, with_preamble(&f.cred, http.as_bytes())).await;
        assert_eq!(
            status(&reply),
            403,
            "{method} {path} must be 403; got {}",
            text(&reply)
        );
        assert!(
            text(&reply).contains("refused:lemonade-relay:"),
            "{method} {path}: refusal must be named; got {}",
            text(&reply)
        );
    }
    // Plain route refusals carry the route-not-allowed name and the path.
    let reply = exchange(
        &f.relay,
        with_preamble(&f.cred, &post_json("/api/v1/pull", &model_body, "")),
    )
    .await;
    assert!(
        text(&reply).contains("refused:lemonade-relay:route-not-allowed:/api/v1/pull"),
        "got {}",
        text(&reply)
    );
    // A query string on a body route.
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &post_json("/api/v1/chat/completions?stream=true", &model_body, ""),
        ),
    )
    .await;
    assert_eq!(
        status(&reply),
        403,
        "query on a body route: {}",
        text(&reply)
    );
    // A websocket upgrade on an allowlisted path.
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &post_json(
                "/api/v1/chat/completions",
                &model_body,
                "Connection: Upgrade\r\nUpgrade: websocket\r\n",
            ),
        ),
    )
    .await;
    assert_eq!(status(&reply), 403, "websocket upgrade: {}", text(&reply));
    assert_eq!(
        f.stub.accepts.load(Ordering::SeqCst),
        0,
        "no refused route may open an upstream connection"
    );
}

#[tokio::test]
async fn an_allowlisted_request_reaches_upstream_with_rebuilt_headers() {
    let f = fixture().await;
    let body = format!("{{\"model\":\"{APPROVED}\",\"messages\":[]}}");
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &post_json(
                "/api/v1/chat/completions",
                &body,
                "Authorization: Bearer guest-secret\r\nCookie: a=b\r\n\
                 X-Forwarded-For: 10.0.42.9\r\nX-Forwarded-Host: evil\r\n",
            ),
        ),
    )
    .await;
    assert_eq!(status(&reply), 200, "got {}", text(&reply));
    assert!(text(&reply).ends_with("{\"ok\":true}"));
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 1);
    let seen = f.stub.seen.lock().unwrap();
    let req = String::from_utf8_lossy(&seen[0]).into_owned();
    let lower = req.to_ascii_lowercase();
    assert!(
        req.starts_with("POST /api/v1/chat/completions HTTP/1.1\r\n"),
        "{req}"
    );
    assert!(lower.contains("\r\nhost: 127.0.0.1:13305\r\n"), "{req}");
    assert!(
        !lower.contains("lemonade:13305"),
        "guest Host must not pass: {req}"
    );
    assert!(
        lower.contains("\r\ncontent-type: application/json\r\n"),
        "{req}"
    );
    assert!(!lower.contains("authorization"), "{req}");
    assert!(!lower.contains("cookie"), "{req}");
    assert!(!lower.contains("x-forwarded"), "{req}");
    assert!(lower.contains("\r\nconnection: close\r\n"), "{req}");
    assert!(req.ends_with(&body), "{req}");
}

#[tokio::test]
async fn an_unapproved_model_is_refused_in_json_and_in_multipart() {
    let f = fixture().await;
    for body in [
        "{\"model\":\"Evil-Model\"}".to_string(),
        "{\"messages\":[]}".to_string(),
        // duplicate key: a parser that keeps the first would see the evil one
        format!("{{\"model\":\"Evil-Model\",\"model\":\"{APPROVED}\"}}"),
        "[1,2]".to_string(),
        "not json".to_string(),
    ] {
        let reply = exchange(
            &f.relay,
            with_preamble(&f.cred, &post_json("/api/v1/chat/completions", &body, "")),
        )
        .await;
        assert!(
            matches!(status(&reply), 400 | 403),
            "{body}: must be refused, got {}",
            text(&reply)
        );
        assert!(
            text(&reply).contains("refused:lemonade-relay:"),
            "{}",
            text(&reply)
        );
    }
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &post_json("/api/v1/chat/completions", "{\"model\":\"Evil-Model\"}", ""),
        ),
    )
    .await;
    assert!(
        text(&reply).contains("refused:lemonade-relay:model-not-approved:Evil-Model"),
        "{}",
        text(&reply)
    );

    for parts in [
        vec![("model", "Evil-Model")],
        vec![("model", APPROVED_ASR), ("model", "Evil-Model")],
        vec![("language", "en")],
    ] {
        let reply = exchange(
            &f.relay,
            with_preamble(&f.cred, &multipart("/api/v1/audio/transcriptions", &parts)),
        )
        .await;
        assert_eq!(status(&reply), 403, "{parts:?}: {}", text(&reply));
        assert!(
            text(&reply).contains("refused:lemonade-relay:model-"),
            "{}",
            text(&reply)
        );
    }
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);

    // The approved multipart model passes.
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &multipart("/api/v1/audio/transcriptions", &[("model", APPROVED_ASR)]),
        ),
    )
    .await;
    assert_eq!(status(&reply), 200, "{}", text(&reply));
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 1);
}

fn multipart(path: &str, fields: &[(&str, &str)]) -> Vec<u8> {
    let b = "XbOuNdArYx";
    let mut body = String::new();
    for (name, value) in fields {
        body.push_str(&format!(
            "--{b}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
        ));
    }
    body.push_str(&format!(
        "--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n\
         Content-Type: audio/wav\r\n\r\nRIFF....\r\n--{b}--\r\n"
    ));
    format!(
        "POST {path} HTTP/1.1\r\nHost: lemonade\r\nContent-Type: multipart/form-data; boundary={b}\r\n\
         Content-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

#[tokio::test]
async fn content_length_with_transfer_encoding_is_refused() {
    let f = fixture().await;
    let body = format!("{{\"model\":\"{APPROVED}\"}}");
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            &post_json(
                "/api/v1/chat/completions",
                &body,
                "Transfer-Encoding: chunked\r\n",
            ),
        ),
    )
    .await;
    assert_eq!(status(&reply), 400, "{}", text(&reply));
    assert!(
        text(&reply).contains("refused:lemonade-relay:content-length-with-transfer-encoding"),
        "{}",
        text(&reply)
    );
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn an_oversized_body_is_refused_before_it_is_read() {
    let f = fixture().await;
    for (path, cl) in [
        ("/api/v1/chat/completions", JSON_BODY_CAP + 1),
        ("/api/v1/embeddings", JSON_BODY_CAP + 1),
        ("/api/v1/audio/transcriptions", MEDIA_BODY_CAP + 1),
        ("/api/v1/images/edits", MEDIA_BODY_CAP + 1),
    ] {
        let http = format!(
            "POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\
             Content-Length: {cl}\r\n\r\n{{\"model\":\"{APPROVED}\"}}"
        );
        let reply = exchange(&f.relay, with_preamble(&f.cred, http.as_bytes())).await;
        assert_eq!(status(&reply), 413, "{path}: {}", text(&reply));
        assert!(text(&reply).contains("refused:lemonade-relay:body-too-large"));
    }
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_bad_credential_is_dropped_silently_with_no_upstream_connection() {
    let f = fixture().await;
    let body = format!("{{\"model\":\"{APPROVED}\"}}");
    let http = post_json("/api/v1/chat/completions", &body, "");
    let forged = LaneCredential::for_test("forge-doris-1", &"00".repeat(32));
    let unknown = LaneCredential::for_test("forge-nobody", &f.cred.token_hex_for_test());
    let mut cases: Vec<Vec<u8>> = vec![
        http.clone(), // no preamble at all
        with_preamble(&forged, &http),
        with_preamble(&unknown, &http),
        b"LRLY1 forge-doris-1\n".to_vec(),
    ];
    // A rotated (relaunched) lane: the old token stops working.
    let old = f.cred.clone();
    let _new = f.relay.lanes().mint("forge-doris-1");
    cases.push(with_preamble(&old, &http));
    for raw in cases {
        let reply = exchange(&f.relay, raw).await;
        assert!(
            reply.is_empty(),
            "a bad credential must get no bytes; got {}",
            text(&reply)
        );
    }
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn get_models_is_built_from_the_approved_set_without_upstream() {
    let f = fixture().await;
    let reply = exchange(
        &f.relay,
        with_preamble(
            &f.cred,
            b"GET /api/v1/models HTTP/1.1\r\nHost: lemonade:13305\r\n\r\n",
        ),
    )
    .await;
    assert_eq!(status(&reply), 200, "{}", text(&reply));
    let t = text(&reply);
    let body = &t[t.find("\r\n\r\n").unwrap() + 4..];
    let v: serde_json::Value = serde_json::from_str(body).unwrap();
    let ids: Vec<&str> = v["data"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![APPROVED, APPROVED_ASR]);
    assert_eq!(v["object"], "list");
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_lane_at_its_concurrency_cap_is_refused() {
    let f = fixture().await;
    let gate = f
        .relay
        .lanes()
        .verify(f.cred.lane(), &f.cred.token_hex_for_test())
        .expect("minted lane verifies");
    let _held = gate
        .clone()
        .try_acquire_many_owned(PER_LANE_CONCURRENCY)
        .unwrap();
    let body = format!("{{\"model\":\"{APPROVED}\"}}");
    let reply = exchange(
        &f.relay,
        with_preamble(&f.cred, &post_json("/api/v1/chat/completions", &body, "")),
    )
    .await;
    assert_eq!(status(&reply), 429, "{}", text(&reply));
    assert!(text(&reply).contains("refused:lemonade-relay:lane-concurrency-cap"));
    assert_eq!(f.stub.accepts.load(Ordering::SeqCst), 0);
}

#[test]
fn approved_models_is_the_downloaded_set_for_now() {
    let got = approved_models(&["b".to_string(), "a".to_string(), "a".to_string()]);
    assert_eq!(got.into_iter().collect::<Vec<_>>(), vec!["a", "b"]);
}

#[test]
fn the_tray_default_upstream_is_fixed_loopback_13305() {
    assert_eq!(
        RelayConfig::tray_default().upstream,
        "127.0.0.1:13305".parse::<std::net::SocketAddr>().unwrap()
    );
}

#[test]
fn a_credential_never_prints_its_token() {
    let f = LaneRegistry::default().mint("lane-x");
    let shown = format!("{f:?}");
    assert!(!shown.contains(&f.token_hex_for_test()), "{shown}");
}

#[test]
fn downloaded_models_are_read_from_a_lemonade_listing() {
    let body =
        r#"{"data":[{"id":"A","downloaded":true},{"id":"B","downloaded":false},{"id":"C"}]}"#;
    assert_eq!(
        parse_downloaded_models(body.as_bytes()).unwrap(),
        vec!["A", "C"]
    );
}
