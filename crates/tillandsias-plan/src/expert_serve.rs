//! `expert-serve` — the OpenAI-compatible loopback front-end over
//! [`crate::pipeline::run_grounded`].
//!
//! @trace spec:expert-serve-grounded-pipeline
//! @trace order:920-pxg6
//!
//! Hand-rolled HTTP/1.1 on a tokio `TcpListener` bound 127.0.0.1 — the
//! `crates/tillandsias-static-server` precedent, no new dependencies. The
//! model id IS the domain selector (all|spec|code|methodology|cheatsheet),
//! so an OpenCode agent picks its expert by picking a model. Refusal
//! envelopes are rendered VERBATIM as completion content with HTTP 200 and
//! `finish_reason: stop`: to the consumer a refusal is a successful
//! completion whose text is the typed refusal — never a 5xx, never a third
//! state.
//!
//! Lifetime: serves until stdin EOF (`</dev/null` exits immediately, which
//! keeps litmus:expert-capability-skew-honesty's invoke-every-token sweep
//! fast). One pinned line on stderr at start; NOTHING on stdout — stdout
//! stays clean for callers that pipe this binary.

use crate::answer::{Envelope, Freshness};
use crate::lua_runtime::SharedLuaRuntime;
use crate::pipeline::{self, GroundedConfig};
use crate::spec_index::SpecIndexEntry;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

/// The five servable model ids — each id selects a retrieval domain.
pub const MODEL_IDS: &[&str] = &["all", "spec", "code", "methodology", "cheatsheet"];

/// Default loopback port: one above the inference container's 11434 and the
/// conventional 11435 embed alias, so the three never collide on a dev host.
pub const DEFAULT_PORT: u16 = 11436;

/// Bodies past this are refused with a 400 — the endpoint takes questions,
/// not corpora.
const MAX_BODY: usize = 1 << 20;

#[derive(Clone)]
pub struct ServeConfig {
    pub port: u16,
    /// Checkout root: citations are validated against it, and the Lua
    /// tier/trim/collect scripts load from
    /// `<root>/crates/tillandsias-plan/lua`.
    pub root: PathBuf,
    pub grounded: GroundedConfig,
    /// Exact entry directory override (tests and pinned deployments);
    /// None = the 879-gidx resolution ladder, re-run per request.
    pub index_dir: Option<PathBuf>,
}

struct CachedEntry {
    dir: PathBuf,
    mtime: Option<SystemTime>,
    entry: Arc<SpecIndexEntry>,
}

struct ServerState {
    cfg: ServeConfig,
    /// None when the Lua scripts failed to load; every request then refuses
    /// typed with the recorded reason (fail-soft, still OpenAI-shaped).
    lua: Option<SharedLuaRuntime>,
    lua_error: Option<String>,
    /// `current` moves under long-lived servers, so the entry is re-resolved
    /// per request; the cache only skips re-parsing an unchanged file.
    entry_cache: tokio::sync::Mutex<Option<CachedEntry>>,
    counter: AtomicU64,
}

impl ServerState {
    /// Re-resolve and (re)load the served entry. Cheap when nothing moved:
    /// the cache is keyed on the resolved dir + chunks.jsonl mtime.
    async fn entry(&self) -> Result<Arc<SpecIndexEntry>, String> {
        let dir = match &self.cfg.index_dir {
            Some(d) => d.clone(),
            None => PathBuf::from(crate::spec_index::resolve_dir().ok_or_else(|| {
                "no rung of the spec-index resolution ladder names a usable index (vectors.jsonl) — scripts/spec-index-ensure.sh builds and publishes one (801-a2by)"
                    .to_string()
            })?),
        };
        let mtime = std::fs::metadata(dir.join("chunks.jsonl"))
            .and_then(|m| m.modified())
            .ok();
        let mut cache = self.entry_cache.lock().await;
        if let Some(c) = cache.as_ref()
            && c.dir == dir
            && c.mtime == mtime
        {
            return Ok(c.entry.clone());
        }
        let entry = Arc::new(SpecIndexEntry::load_dir(&dir)?);
        *cache = Some(CachedEntry {
            dir,
            mtime,
            entry: entry.clone(),
        });
        Ok(entry)
    }
}

// ── response builders (pure, unit-tested) ───────────────────────────────────

fn epoch_now() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The static model listing: exactly the five domain ids.
pub fn models_json() -> serde_json::Value {
    let created = epoch_now();
    serde_json::json!({
        "object": "list",
        "data": MODEL_IDS.iter().map(|id| serde_json::json!({
            "id": id,
            "object": "model",
            "created": created,
            "owned_by": "tillandsias-plan",
        })).collect::<Vec<_>>(),
    })
}

/// The non-streaming completion. `rag_source_commit` is the served entry's
/// own frame (the envelope's freshness commit — 801-g9nn), NEVER this
/// process's HEAD; `tillandsias_envelope` carries the full ratified envelope
/// so a caller can pipe it straight into `verify-answer`.
pub fn completion_json(id: u64, model: &str, envelope: &Envelope) -> serde_json::Value {
    serde_json::json!({
        "id": format!("expert-serve-{id}"),
        "object": "chat.completion",
        "created": epoch_now(),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": envelope.answer()},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "rag_source_commit": envelope.freshness().source_commit(),
        "tillandsias_envelope": envelope,
    })
}

/// The SSE stream body: role delta, one content delta carrying the whole
/// answer (the pipeline completes before framing — see the module doc's
/// non-goal), the stop chunk with `rag_source_commit`, then the pinned
/// `data: [DONE]` terminator.
pub fn sse_body(id: u64, model: &str, envelope: &Envelope) -> String {
    let created = epoch_now();
    let base = |delta: serde_json::Value, finish: serde_json::Value| {
        serde_json::json!({
            "id": format!("expert-serve-{id}"),
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        })
    };
    let role = base(
        serde_json::json!({"role": "assistant"}),
        serde_json::Value::Null,
    );
    let content = base(
        serde_json::json!({"content": envelope.answer()}),
        serde_json::Value::Null,
    );
    let mut stop = base(serde_json::json!({}), serde_json::json!("stop"));
    stop["rag_source_commit"] = serde_json::json!(envelope.freshness().source_commit());
    format!("data: {role}\n\ndata: {content}\n\ndata: {stop}\n\ndata: [DONE]\n\n")
}

fn error_json(message: &str) -> String {
    serde_json::json!({
        "error": {"message": message, "type": "invalid_request_error"}
    })
    .to_string()
}

/// The user text a chat request asks about: the LAST user message, with
/// OpenAI's string and content-part forms both accepted.
pub fn last_user_content(body: &serde_json::Value) -> Option<String> {
    let messages = body.get("messages")?.as_array()?;
    for m in messages.iter().rev() {
        if m.get("role").and_then(|r| r.as_str()) != Some("user") {
            continue;
        }
        match m.get("content") {
            Some(serde_json::Value::String(s)) if !s.trim().is_empty() => {
                return Some(s.trim().to_string());
            }
            Some(serde_json::Value::Array(parts)) => {
                let text: String = parts
                    .iter()
                    .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
                    .collect::<Vec<_>>()
                    .join("\n");
                if !text.trim().is_empty() {
                    return Some(text.trim().to_string());
                }
            }
            _ => {}
        }
    }
    None
}

// ── the server ──────────────────────────────────────────────────────────────

async fn write_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &str,
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.flush().await
}

async fn handle_connection(mut stream: TcpStream, state: Arc<ServerState>) -> std::io::Result<()> {
    let mut request_line = String::new();
    let mut content_length: usize = 0;
    {
        let mut reader = BufReader::new(&mut stream);
        reader.read_line(&mut request_line).await?;
        loop {
            let mut header = String::new();
            let n = reader.read_line(&mut header).await?;
            if n == 0 || header == "\r\n" || header == "\n" {
                break;
            }
            if let Some((name, value)) = header.split_once(':')
                && name.eq_ignore_ascii_case("content-length")
            {
                content_length = value.trim().parse().unwrap_or(0);
            }
        }
        if content_length > MAX_BODY {
            drop(reader);
            return write_response(
                &mut stream,
                400,
                "application/json",
                &error_json("request body too large"),
            )
            .await;
        }
        if content_length > 0 {
            let mut body = vec![0u8; content_length];
            reader.read_exact(&mut body).await?;
            drop(reader);
            let body_str = String::from_utf8_lossy(&body).into_owned();
            return route(&mut stream, &request_line, Some(body_str), state).await;
        }
    }
    route(&mut stream, &request_line, None, state).await
}

async fn route(
    stream: &mut TcpStream,
    request_line: &str,
    body: Option<String>,
    state: Arc<ServerState>,
) -> std::io::Result<()> {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let path = target.split('?').next().unwrap_or("/");

    match (method, path) {
        ("GET", "/v1/models") => {
            write_response(stream, 200, "application/json", &models_json().to_string()).await
        }
        ("POST", "/v1/chat/completions") => {
            let parsed: Option<serde_json::Value> =
                body.as_deref().and_then(|b| serde_json::from_str(b).ok());
            let Some(req) = parsed else {
                return write_response(
                    stream,
                    400,
                    "application/json",
                    &error_json("body is not a JSON chat-completions request"),
                )
                .await;
            };
            let model = req
                .get("model")
                .and_then(|m| m.as_str())
                .unwrap_or("all")
                .to_string();
            if !MODEL_IDS.contains(&model.as_str()) {
                return write_response(
                    stream,
                    404,
                    "application/json",
                    &error_json(&format!(
                        "unknown model {model:?} — the served ids are the retrieval domains: all, spec, code, methodology, cheatsheet"
                    )),
                )
                .await;
            }
            let stream_requested = req.get("stream").and_then(|s| s.as_bool()).unwrap_or(false);
            let Some(query) = last_user_content(&req) else {
                return write_response(
                    stream,
                    400,
                    "application/json",
                    &error_json("no user message content to answer"),
                )
                .await;
            };

            let envelope = answer_query(&state, &model, &query).await;
            let id = state.counter.fetch_add(1, Ordering::SeqCst);
            if stream_requested {
                write_response(
                    stream,
                    200,
                    "text/event-stream",
                    &sse_body(id, &model, &envelope),
                )
                .await
            } else {
                write_response(
                    stream,
                    200,
                    "application/json",
                    &completion_json(id, &model, &envelope).to_string(),
                )
                .await
            }
        }
        _ => {
            write_response(
                stream,
                404,
                "application/json",
                &error_json(&format!("no route for {method} {path}")),
            )
            .await
        }
    }
}

/// One request through the ONE pipeline. Every failure shape is an envelope:
/// the refusal grammar is the contract, HTTP errors are only for malformed
/// requests.
async fn answer_query(state: &ServerState, model: &str, query: &str) -> Envelope {
    let unknown = || Freshness::new("unknown".to_string(), "unknown".to_string());
    let Some(lua) = &state.lua else {
        return Envelope::unsupported(
            format!(
                "the Lua tier/trim/collect scripts failed to load: {}",
                state.lua_error.as_deref().unwrap_or("unknown error")
            ),
            unknown(),
        );
    };
    let entry = match state.entry().await {
        Ok(e) => e,
        Err(e) => return Envelope::unsupported(e, unknown()),
    };
    let mut cfg = state.cfg.grounded.clone();
    cfg.inference.domain = if model == "all" {
        None
    } else {
        Some(model.to_string())
    };
    pipeline::run_grounded(lua, &entry, &cfg, query).await
}

/// Serve until `shutdown` fires. `bound` (when supplied) receives the port
/// actually bound — the port-0 seam the integration tests use.
pub async fn serve(
    cfg: ServeConfig,
    bound: Option<std::sync::mpsc::Sender<u16>>,
    mut shutdown: tokio::sync::oneshot::Receiver<()>,
) -> Result<(), String> {
    let listener = TcpListener::bind(("127.0.0.1", cfg.port))
        .await
        .map_err(|e| format!("failed to bind 127.0.0.1:{}: {e}", cfg.port))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("no local addr: {e}"))?
        .port();

    let (lua, lua_error) = match crate::lua_runtime::create_shared_runtime(&cfg.root) {
        Ok(rt) => (Some(rt), None),
        Err(e) => (None, Some(e.to_string())),
    };
    if let Some(e) = &lua_error {
        eprintln!("expert-serve: lua unavailable ({e}) — every request will refuse typed");
    }

    // THE PINNED LINE — and the only startup output. stdout stays silent.
    eprintln!(
        "expert-serve: listening on http://127.0.0.1:{port} root={} domains=all|spec|code|methodology|cheatsheet",
        cfg.root.display()
    );
    if let Some(tx) = bound {
        let _ = tx.send(port);
    }

    let state = Arc::new(ServerState {
        cfg,
        lua,
        lua_error,
        entry_cache: tokio::sync::Mutex::new(None),
        counter: AtomicU64::new(0),
    });

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let state = state.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(stream, state).await {
                                eprintln!("expert-serve: request failed: {e}");
                            }
                        });
                    }
                    Err(e) => eprintln!("expert-serve: accept failed: {e}"),
                }
            }
        }
    }
    Ok(())
}

/// The binary entry point: builds the runtime, wires stdin EOF to shutdown
/// (a reader thread — `</dev/null` fires immediately), and serves. Returns
/// the process exit code.
pub fn run_blocking(cfg: ServeConfig) -> i32 {
    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("expert-serve: tokio runtime init failed: {e}");
            return 1;
        }
    };
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        use std::io::Read;
        let mut buf = [0u8; 4096];
        let mut stdin = std::io::stdin();
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
        }
        let _ = shutdown_tx.send(());
    });
    match rt.block_on(serve(cfg, None, shutdown_rx)) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("expert-serve: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::answer::Confidence;
    use crate::pipeline::InferenceConfig;
    use std::io::{Read, Write};
    use std::path::Path;
    use std::time::Duration;

    fn sample_envelope() -> Envelope {
        use crate::answer::{Citation, CitationKind};
        use std::collections::BTreeMap;
        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), "the-key".to_string());
        Envelope::supported(
            "the-key answer",
            vec![Citation::new(
                "openspec/specs/x/spec.md".to_string(),
                1,
                2,
                CitationKind::Spec,
                authority,
            )],
            Confidence::Retrieved,
            Freshness::new(
                "abcdef1234567890abcdef1234567890abcdef12".to_string(),
                "2026-08-28T00:00:00Z".to_string(),
            ),
        )
    }

    #[test]
    fn completion_json_is_openai_shaped_with_the_entry_frame() {
        let v = completion_json(7, "spec", &sample_envelope());
        assert_eq!(v["object"], "chat.completion");
        assert_eq!(v["model"], "spec");
        assert_eq!(v["choices"][0]["message"]["role"], "assistant");
        assert_eq!(v["choices"][0]["message"]["content"], "the-key answer");
        assert_eq!(v["choices"][0]["finish_reason"], "stop");
        assert_eq!(
            v["rag_source_commit"],
            "abcdef1234567890abcdef1234567890abcdef12"
        );
        // The full envelope rides along for verify-answer.
        assert_eq!(v["tillandsias_envelope"]["confidence"], "retrieved");
    }

    #[test]
    fn sse_body_frames_chunks_and_terminates_with_done() {
        let body = sse_body(1, "all", &sample_envelope());
        assert!(body.starts_with("data: "));
        assert!(body.contains("chat.completion.chunk"));
        assert!(body.contains("\"content\":\"the-key answer\""));
        assert!(body.contains("\"finish_reason\":\"stop\""));
        assert!(body.trim_end().ends_with("data: [DONE]"));
        // SSE events are blank-line separated.
        assert!(body.contains("}\n\ndata: "));
    }

    #[test]
    fn models_json_lists_exactly_the_five_domains() {
        let v = models_json();
        let ids: Vec<&str> = v["data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(
            ids,
            vec!["all", "spec", "code", "methodology", "cheatsheet"]
        );
    }

    #[test]
    fn last_user_content_handles_string_and_part_forms() {
        let req = serde_json::json!({"messages": [
            {"role": "system", "content": "s"},
            {"role": "user", "content": "first"},
            {"role": "assistant", "content": "a"},
            {"role": "user", "content": [{"type": "text", "text": "second"}]},
        ]});
        assert_eq!(last_user_content(&req).as_deref(), Some("second"));
        assert_eq!(
            last_user_content(&serde_json::json!({"messages": []})),
            None
        );
    }

    // ── integration on port 0 ───────────────────────────────────────────────

    fn repo_root() -> PathBuf {
        // CARGO_MANIFEST_DIR = <repo>/crates/tillandsias-plan; the Lua
        // scripts resolve from the repo root.
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(2)
            .expect("repo root")
            .to_path_buf()
    }

    fn fixture_entry(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tilland-serve-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("entry dir");
        let chunk = serde_json::json!({
            "id": 0, "path": "README.md", "line_start": 1, "line_end": 2,
            "kind": "spec", "key": "fixture-key", "content_hash": "0",
            "text": "fixture-key body",
        });
        std::fs::write(dir.join("chunks.jsonl"), format!("{chunk}\n")).unwrap();
        std::fs::write(dir.join("vectors.jsonl"), "[1.0,0.0]\n").unwrap();
        std::fs::write(
            dir.join(".commit"),
            "abcdef1234567890abcdef1234567890abcdef12\n",
        )
        .unwrap();
        dir
    }

    fn http(port: u16, request: &str) -> String {
        let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        s.write_all(request.as_bytes()).unwrap();
        let mut out = String::new();
        let _ = s.read_to_string(&mut out);
        out
    }

    fn post(port: u16, path: &str, body: &str) -> String {
        http(
            port,
            &format!(
                "POST {path} HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ),
        )
    }

    /// End-to-end on port 0: /v1/models, 404, the typed refusal as a 200
    /// completion (no embed endpoint configured), SSE framing, and the
    /// fast shutdown seam the stdin-EOF thread drives in production.
    #[test]
    fn integration_refusal_models_404_and_shutdown() {
        let entry_dir = fixture_entry("integration");
        let cfg = ServeConfig {
            port: 0,
            root: repo_root(),
            grounded: GroundedConfig {
                inference: InferenceConfig {
                    synth_base: "http://127.0.0.1:9/v1".to_string(),
                    embed_base: None,
                    model: "stub".to_string(),
                    embed_model: Some("stub".to_string()),
                    timeout: Duration::from_millis(300),
                    domain: None,
                },
                root: repo_root(),
            },
            index_dir: Some(entry_dir.clone()),
        };
        let (btx, brx) = std::sync::mpsc::channel();
        let (stx, srx) = tokio::sync::oneshot::channel();
        let handle = std::thread::spawn(move || {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(serve(cfg, Some(btx), srx)).unwrap();
        });
        let port = brx
            .recv_timeout(Duration::from_secs(30))
            .expect("server binds and reports its port");

        // GET /v1/models — the five ids.
        let models = http(
            port,
            "GET /v1/models HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
        );
        assert!(models.starts_with("HTTP/1.1 200"), "{models}");
        for id in MODEL_IDS {
            assert!(models.contains(&format!("\"id\":\"{id}\"")), "{models}");
        }

        // Unknown route — 404 JSON.
        let missing = http(
            port,
            "GET /nope HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
        );
        assert!(missing.starts_with("HTTP/1.1 404"), "{missing}");
        assert!(missing.contains("\"error\""));

        // Typed refusal end-to-end: no embed endpoint => HTTP 200 whose
        // content is the pinned refusal, finish_reason stop, and the
        // rag_source_commit is the ENTRY's commit.
        let refusal = post(
            port,
            "/v1/chat/completions",
            r#"{"model":"spec","messages":[{"role":"user","content":"what governs the forge?"}]}"#,
        );
        assert!(refusal.starts_with("HTTP/1.1 200"), "{refusal}");
        let json_start = refusal.find("\r\n\r\n").unwrap() + 4;
        let v: serde_json::Value = serde_json::from_str(&refusal[json_start..]).unwrap();
        let content = v["choices"][0]["message"]["content"].as_str().unwrap();
        assert!(content.starts_with("unsupported: "), "{content}");
        assert_eq!(v["choices"][0]["finish_reason"], "stop");
        assert_eq!(
            v["rag_source_commit"],
            "abcdef1234567890abcdef1234567890abcdef12"
        );
        assert_eq!(v["tillandsias_envelope"]["confidence"], "unsupported");
        assert_eq!(
            v["tillandsias_envelope"]["citations"]
                .as_array()
                .unwrap()
                .len(),
            0
        );

        // stream:true — SSE ending with [DONE].
        let sse = post(
            port,
            "/v1/chat/completions",
            r#"{"model":"all","stream":true,"messages":[{"role":"user","content":"anything"}]}"#,
        );
        assert!(sse.contains("text/event-stream"), "{sse}");
        assert!(sse.contains("chat.completion.chunk"));
        assert!(sse.trim_end().ends_with("data: [DONE]"), "{sse}");

        // Shutdown must complete promptly — the stdin-EOF contract.
        let begun = std::time::Instant::now();
        stx.send(()).unwrap();
        handle.join().expect("server thread joins");
        assert!(
            begun.elapsed() < Duration::from_secs(10),
            "shutdown took {:?}",
            begun.elapsed()
        );
        let _ = std::fs::remove_dir_all(&entry_dir);
    }
}
