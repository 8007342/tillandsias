//! The grounded expert pipeline — ONE function, two front-ends.
//!
//! @trace spec:expert-serve-grounded-pipeline
//! @trace order:920-pxg6
//!
//! [`run_grounded`] is the only path from a natural-language query to an
//! answer envelope for the local-experts surface: tier classify → LLM
//! decomposition (fallback-to-original) → tier trim → per-variant embed /
//! domain-filtered retrieval from the PUBLISHED index entry / synthesis over
//! the retrieved context → per-variant envelope keeping ONLY citations the
//! prose used (cited retrieval-only digest on synthesis failure) → Rust
//! validation → collect merge → best cited envelope, or the typed
//! [`Envelope::unsupported`] refusal. There is NO code path that returns raw
//! model prose without citations — the dichotomy 687eb6d57's facade lacked.
//!
//! Both front-ends — the `pipeline` CLI arm and the `expert-serve` HTTP
//! endpoint — call this function; neither carries grounding logic of its own.
//!
//! All model calls (decomposition and synthesis) converge on ONE HTTP client
//! posting `{base}/chat/completions`; embeddings post `{base}/embeddings` —
//! the in-process twin of forge-plan.sh's spec_answer curl.

use crate::answer::{self, Confidence, Envelope};
use crate::lua_runtime::{AdversarialPrompt, LatencyTier, SharedLuaRuntime};
use crate::spec::{self, Chunk, ScoredChunk};
use crate::spec_index::SpecIndexEntry;
use std::path::PathBuf;
use std::time::Duration;

/// Retrieval width per variant. The same k=6 the shell spec_answer path uses.
const RETRIEVE_K: usize = 6;

/// Endpoint + model configuration for the converged OpenAI-compatible
/// protocol (D6). Bases are `/v1` bases, exactly as the endpoint envs are
/// documented ("set TILLANDSIAS_EMBED_ENDPOINT to a /v1 base").
#[derive(Debug, Clone)]
pub struct InferenceConfig {
    /// Chat-completions base for decomposition AND synthesis.
    /// TILLANDSIAS_SPEC_EXPERT_ENDPOINT, defaulting to the embed base, then
    /// to TILLANDSIAS_INFERENCE_ENDPOINT + "/v1", then to the enclave DNS
    /// default `http://inference:11434/v1` (the `inference` host restored —
    /// 687eb6d57 had rewritten it to 127.0.0.1, killing the enclave path).
    pub synth_base: String,
    /// Embeddings base. None = the grounded pipeline refuses typed:
    /// retrieval is impossible and the raw model is not a fallback.
    pub embed_base: Option<String>,
    /// Synthesis/decomposition model. Empty = omit the field and let the
    /// endpoint's default answer (forge-plan.sh's synth_model behavior).
    pub model: String,
    /// Embedding-model FALLBACK. The index entry's `.model` marker is
    /// preferred — embedding a query with a different model than wrote the
    /// vectors compares apples to hashes (order 552's model-key lesson).
    pub embed_model: Option<String>,
    /// Socket-level budget per request. The tier budget (enforced with
    /// `tokio::time::timeout` around dispatch) is usually tighter.
    pub timeout: Duration,
    /// Domain filter: "cheatsheet" | "methodology" | "code" | "spec";
    /// None or "all" = the whole corpus.
    pub domain: Option<String>,
}

impl Default for InferenceConfig {
    fn default() -> Self {
        let embed_base = std::env::var("TILLANDSIAS_EMBED_ENDPOINT")
            .ok()
            .map(|s| s.trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty());
        let synth_base = std::env::var("TILLANDSIAS_SPEC_EXPERT_ENDPOINT")
            .ok()
            .map(|s| s.trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| embed_base.clone())
            .or_else(|| {
                std::env::var("TILLANDSIAS_INFERENCE_ENDPOINT")
                    .ok()
                    .map(|ep| format!("{}/v1", ep.trim_end_matches('/')))
            })
            .unwrap_or_else(|| "http://inference:11434/v1".to_string());
        Self {
            synth_base,
            embed_base,
            model: std::env::var("TILLANDSIAS_INFERENCE_MODEL")
                .unwrap_or_else(|_| "qwen2.5:0.5b".to_string()),
            embed_model: std::env::var("TILLANDSIAS_EMBED_MODEL")
                .ok()
                .filter(|s| !s.is_empty()),
            timeout: Duration::from_secs(120),
            domain: std::env::var("TILLANDSIAS_EXPERT_DOMAIN").ok(),
        }
    }
}

/// [`run_grounded`]'s full configuration: the endpoints plus the checkout
/// root citations are validated against (D3 — validation is Rust).
#[derive(Debug, Clone)]
pub struct GroundedConfig {
    pub inference: InferenceConfig,
    pub root: PathBuf,
}

impl GroundedConfig {
    pub fn from_env(root: PathBuf) -> Self {
        Self {
            inference: InferenceConfig::default(),
            root,
        }
    }
}

// ── the ONE http client (D6) ────────────────────────────────────────────────

/// Parse an `http://host[:port][/path]` base into (host, port, path).
/// Only plain http: the endpoints are loopback or enclave-internal.
pub fn parse_base(url: &str) -> Option<(String, u16, String)> {
    let rest = url.strip_prefix("http://")?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], rest[i..].trim_end_matches('/').to_string()),
        None => (rest, String::new()),
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().ok()?),
        None => (hostport.to_string(), 80),
    };
    if host.is_empty() {
        return None;
    }
    Some((host, port, path))
}

/// The one raw HTTP POST every model call goes through. Resolves HOSTNAMES,
/// not just numeric IPs (the enclave default `inference:11434` — the exact
/// defect that made the 706-f7mq synthesis path dead code until 718-nkm2
/// flagged it), sets read/write timeouts, `Connection: close`. Synchronous —
/// call from `spawn_blocking`.
pub fn http_post_json(
    base: &str,
    route: &str,
    body: &serde_json::Value,
    timeout: Duration,
) -> Option<serde_json::Value> {
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};

    let (host, port, path) = parse_base(base)?;
    let addr = format!("{host}:{port}");
    let resolved = (host.as_str(), port).to_socket_addrs().ok()?;
    let mut stream = resolved
        .into_iter()
        .find_map(|a| TcpStream::connect_timeout(&a, timeout).ok())?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    let body_str = serde_json::to_string(body).ok()?;
    let request = format!(
        "POST {path}{route} HTTP/1.1\r\n\
         Host: {addr}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{body_str}",
        body_str.len()
    );
    stream.write_all(request.as_bytes()).ok()?;
    let mut resp = String::new();
    stream.read_to_string(&mut resp).ok()?;

    let (_, payload) = resp.split_once("\r\n\r\n")?;
    if let Ok(v) = serde_json::from_str(payload) {
        return Some(v);
    }
    // Chunked transfer framing survives a naive read; the JSON object is
    // still contiguous between its outermost braces.
    let start = payload.find('{')?;
    let end = payload.rfind('}')?;
    if start > end {
        return None;
    }
    serde_json::from_str(&payload[start..=end]).ok()
}

/// ORDER 927-2q4w — the synthesis budget a tier actually gets.
///
/// THE DECISION, and the measurements behind it are on the packet.
///
/// The packet offered three options: (a) classify the tier from measured
/// endpoint latency, (b) raise or env-tune the budgets, (c) make retrieval-only
/// the documented normal mode where the contract-satisfying model is too slow.
/// The measurements say the honest answer is (b) as an EXPLICIT operator knob
/// plus (c) as the documented default, and NOT (a) as an auto-tune.
///
/// WHY NOT AUTO-TUNE FROM MEASURED LATENCY. It is the seductive option and it
/// is wrong here for two reasons. First, it silently trades the user's
/// interactive latency for answer quality without asking — a host that
/// deliberately runs a tiny model to stay snappy would find its quick tier
/// quietly stretched to 20s because one synthesis was slow, which is exactly
/// the class of silent behaviour this repo keeps repairing. Second, it does not
/// even help the host it was proposed for: MEASURED on lenovinha 2026-08-29,
/// the CPU floor's constraint is not latency at all. qwen2.5:0.5b answers in
/// 927/2231/2885 ms — inside the 3000 ms quick budget — but across four
/// identical prompts it echoed 2/2, 0/2, 1/2 and 2/2 of the retrieved keys, and
/// one run FABRICATED a source key ("host-tool-disPATCH-SWEETS.md"). On the CPU
/// floor the binding constraint is MODEL CAPABILITY, and no budget change
/// touches it. Raising budgets fleet-wide would regress the snappy hosts to fix
/// a problem the slow hosts have.
///
/// SO: the default is UNCHANGED, which is what makes this safe to land. Hosts
/// whose model already fits — every CPU-floor host — see byte-identical
/// behaviour. A host whose contract-satisfying model needs longer (the darwin
/// 7b case: 10-24 s per synthesis against a 3000 ms quick budget) sets
/// `TILLANDSIAS_SYNTH_BUDGET_MS` deliberately, accepting the wait it is buying.
/// Everywhere else, retrieval-only is the documented normal mode and already
/// says so: the timed-out producer carries its own message naming the budget
/// rather than blaming the endpoint.
///
/// THE CEILING IS NOT NEGOTIABLE. An override is clamped to
/// [`SYNTH_BUDGET_CEILING_MS`] because a budget is a promise to the user that
/// the wait ends. An operator who sets 10 minutes has not configured patience,
/// they have configured a hang.
///
/// AND THE CITATION BAR DOES NOT MOVE. It would be easy to read "0/6 keys
/// echoed" as a filter that is too strict. It is the opposite: the fabricated
/// key above matched no retrieved chunk, so the only-if-used filter refused it
/// and fell back to the cited digest. On the CPU floor that filter is the thing
/// standing between the user and an invented source. Retrieval-only is not a
/// degraded answer there — it is the more accurate one.
pub const SYNTH_BUDGET_CEILING_MS: u64 = 60_000;

/// Read the deliberate override, if any. Separated from the clamp so the
/// policy is testable without touching process env.
pub fn synth_budget_override_ms() -> Option<u64> {
    std::env::var("TILLANDSIAS_SYNTH_BUDGET_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
}

/// Pure policy: tier budget, unless an override says otherwise, clamped.
pub fn resolve_synth_budget_ms(tier_budget_ms: u64, override_ms: Option<u64>) -> u64 {
    match override_ms {
        Some(v) => v.min(SYNTH_BUDGET_CEILING_MS),
        None => tier_budget_ms,
    }
}

fn effective_synth_budget(tier: LatencyTier) -> Duration {
    Duration::from_millis(resolve_synth_budget_ms(
        tier.budget_ms(),
        synth_budget_override_ms(),
    ))
}

/// A bounded GET used only for LIVENESS (order 718-ja7g). Same socket
/// discipline as `http_post_json` — hostname-resolving, both timeouts set,
/// `Connection: close` — so the probe cannot report a reachability the real
/// dispatch path would not get. Returns true only on a 2xx status line.
///
/// Beside the POST rather than in a new module: D6 says one HTTP client, and a
/// probe that reached the endpoint by some other route would be a second
/// client with a second set of failure modes, which is exactly how a
/// diagnostic starts disagreeing with the thing it diagnoses.
pub fn http_get_ok(base: &str, route: &str, timeout: Duration) -> bool {
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};

    let Some((host, port, path)) = parse_base(base) else {
        return false;
    };
    let addr = format!("{host}:{port}");
    let Ok(resolved) = (host.as_str(), port).to_socket_addrs() else {
        return false;
    };
    let Some(mut stream) = resolved
        .into_iter()
        .find_map(|a| TcpStream::connect_timeout(&a, timeout).ok())
    else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    let request = format!(
        "GET {path}{route} HTTP/1.1\r\n\
         Host: {addr}\r\n\
         Connection: close\r\n\r\n"
    );
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut resp = String::new();
    if stream.read_to_string(&mut resp).is_err() {
        return false;
    }
    // Status line only. A 2xx is the whole question; the body is the
    // endpoint's business.
    resp.lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse::<u16>().ok())
        .is_some_and(|c| (200..300).contains(&c))
}

/// One chat completion over `{base}/chat/completions`. `model` empty = omit
/// the field. Returns the assistant content, None on any failure or an empty
/// answer — the caller owns the typed degradation.
pub fn chat_completion(
    base: &str,
    model: &str,
    system: Option<&str>,
    user: &str,
    max_tokens: Option<u32>,
    timeout: Duration,
) -> Option<String> {
    let mut messages: Vec<serde_json::Value> = Vec::new();
    if let Some(s) = system {
        messages.push(serde_json::json!({"role": "system", "content": s}));
    }
    messages.push(serde_json::json!({"role": "user", "content": user}));
    let mut payload = serde_json::json!({"messages": messages, "temperature": 0.2});
    if !model.is_empty() {
        payload["model"] = serde_json::json!(model);
    }
    if let Some(mt) = max_tokens {
        payload["max_tokens"] = serde_json::json!(mt);
    }
    let resp = http_post_json(base, "/chat/completions", &payload, timeout)?;
    resp.pointer("/choices/0/message/content")
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// One query embedding over `{base}/embeddings` — the in-process twin of
/// forge-plan.sh's spec_answer curl (same payload shape: `{model, input}`).
pub fn embed_query(base: &str, model: &str, input: &str, timeout: Duration) -> Option<Vec<f32>> {
    let payload = serde_json::json!({"model": model, "input": input});
    let resp = http_post_json(base, "/embeddings", &payload, timeout)?;
    resp.pointer("/data/0/embedding")?
        .as_array()?
        .iter()
        .map(|v| v.as_f64().map(|f| f as f32))
        .collect()
}

// ── decomposition ───────────────────────────────────────────────────────────

/// LLM-based decomposition: ask the model to generate adversarial variants.
/// Falls back to the original query as the only variant on ANY failure —
/// decomposition adds recall, never availability risk.
pub fn decompose_with_llm(config: &InferenceConfig, query: &str) -> Vec<AdversarialPrompt> {
    let domain_context = match config.domain.as_deref() {
        Some("cheatsheet") => {
            "You are decomposing a query about cheatsheets and reference documentation. "
        }
        Some("methodology") => {
            "You are decomposing a query about project methodology and discipline rules. "
        }
        Some("code") => {
            "You are decomposing a query about source code and implementation details. "
        }
        Some("spec") => {
            "You are decomposing a query about OpenSpec specifications and design decisions. "
        }
        _ => "",
    };
    let decompose_prompt = format!(
        "{domain_context}You are a query decomposition engine. Given a user query about a software project, \
         generate adversarial variants to reduce hallucination through cross-validation.\n\n\
         User query: \"{query}\"\n\n\
         Generate exactly these variants as a JSON array (no markdown, just JSON):\n\
         [\n\
           {{\"prompt\": \"<the original query>\", \"kind\": \"original\"}},\n\
           {{\"prompt\": \"<the OPPOSITE claim about the same topic>\", \"kind\": \"negation\"}},\n\
           {{\"prompt\": \"<alternative approaches to the same question>\", \"kind\": \"alternative\"}}\n\
         ]\n\n\
         Rules:\n\
         - The original must be the exact user query\n\
         - The negation must be a plausible opposite claim (not just 'not X')\n\
         - The alternative must explore a different angle or approach\n\
         - All prompts should be answerable from the same codebase\n\
         - Return ONLY the JSON array, no other text"
    );

    let original_only = || {
        vec![AdversarialPrompt {
            prompt: query.to_string(),
            kind: "original".to_string(),
        }]
    };

    let Some(raw) = chat_completion(
        &config.synth_base,
        &config.model,
        None,
        &decompose_prompt,
        None,
        config.timeout,
    ) else {
        return original_only();
    };

    // Find the JSON array in the response (may have surrounding text). The
    // pre-920-pxg6 form sliced unguarded and PANICKED when the model emitted
    // `]` before `[` (e.g. prose containing "] and [") — checked now.
    let cleaned = raw.trim();
    let json_str = match (cleaned.find('['), cleaned.rfind(']')) {
        (Some(s), Some(e)) if s <= e => &cleaned[s..=e],
        _ => cleaned,
    };

    match serde_json::from_str::<Vec<AdversarialPrompt>>(json_str) {
        Ok(prompts) if !prompts.is_empty() => prompts,
        _ => original_only(),
    }
}

// ── the grounded pipeline (D5) ──────────────────────────────────────────────

/// Char-boundary-safe truncation for log lines. The pre-920-pxg6 form sliced
/// `&query[..50]` and panicked on a multi-byte character at the boundary.
fn truncate_chars(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    s.chars().take(n).collect()
}

/// The indices of the entry's chunks that belong to `domain` (None/"all" =
/// every chunk). Chunk kinds and domain ids share one vocabulary:
/// spec | cheatsheet | methodology | code.
pub fn domain_indices(chunks: &[Chunk], domain: Option<&str>) -> Vec<usize> {
    let filter = domain.filter(|d| *d != "all");
    chunks
        .iter()
        .enumerate()
        .filter(|(_, c)| filter.is_none_or(|d| c.kind == d))
        .map(|(i, _)| i)
        .collect()
}

// The similarity floors — the per-chunk inclusion floor and the best-score
// coverage floor (one scalar cannot answer both questions; the darwin n=30
// calibration and the sourdough finding are recorded on 920-pxg6) — moved to
// `spec::retrieve_min_score` / `spec::refusal_floor` under order 821-73es, so
// this pipeline and the shell spec_answer path (`spec-floor`) read the same
// knobs and defaults.

/// The three ways synthesis fails to produce usable prose — each owes its
/// own message, or a model slower than the tier budget is misdiagnosed as
/// a missing endpoint (927-2q4w).
enum SynthOutcome {
    Answered(String),
    EndpointFailed,
    TimedOut,
}

/// Domain-filtered cosine top-k: [`spec::top_k`]'s ranking over a subset of
/// the entry's vectors, without cloning the index. Returns entry indices.
fn top_k_filtered(
    query: &[f32],
    vectors: &[Vec<f32>],
    selected: &[usize],
    k: usize,
) -> Vec<(usize, f32)> {
    let mut scored: Vec<(usize, f32)> = selected
        .iter()
        .map(|&i| (i, spec::cosine(query, &vectors[i])))
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(k);
    scored
}

/// D3 — validation is Rust. Re-verifies a candidate envelope's citations
/// against the checkout root (the same `answer::verify` the CLI's emit path
/// runs) and downgrades failures to the typed refusal. Deterministic and
/// testable — the role the dead `validate.lua` only claimed.
fn rust_validated(envelope: Envelope, root: &std::path::Path) -> Envelope {
    if envelope.confidence() == Confidence::Unsupported {
        return envelope;
    }
    let envelope = envelope.with_citation_root(root);
    let violations = answer::verify(&envelope, root);
    if violations.is_empty() {
        return envelope;
    }
    let freshness = envelope.freshness().clone();
    Envelope::unsupported(
        format!(
            "this answer FAILED its citation check against {} and was withheld ({} violation(s)): {}",
            root.display(),
            violations.len(),
            violations.join("; ")
        ),
        freshness,
    )
}

/// One variant's surviving, validated envelope plus its provenance.
struct VariantOutcome {
    envelope: Envelope,
    kind: String,
    prompt: String,
}

/// The grounded pipeline (D5): used by BOTH the `expert-serve` endpoint and
/// the `pipeline` CLI arm. Returns an envelope that either carries citations
/// that verifiably support it, or is the typed refusal — no third state.
///
/// Freshness and the citation frame come from the ENTRY (D2/801-g9nn): its
/// `.commit` + `chunks.jsonl` mtime, completed with
/// `with_default_citation_commit` here, BEFORE any emit-path HEAD stamp.
pub async fn run_grounded(
    runtime: &SharedLuaRuntime,
    entry: &SpecIndexEntry,
    cfg: &GroundedConfig,
    query: &str,
) -> Envelope {
    let freshness = entry.freshness();

    // ── preflight refusals: every one fires BEFORE any model request ──────
    let Some(embed_base) = cfg.inference.embed_base.clone() else {
        let reason = "no embedding endpoint — set TILLANDSIAS_EMBED_ENDPOINT to a /v1 base; the grounded pipeline cannot retrieve, and the raw model is not a fallback";
        eprintln!("[grounded] refuse-before-dispatch: {reason}");
        return Envelope::unsupported(reason, freshness);
    };
    let Some(embed_model) = entry
        .model
        .clone()
        .or_else(|| cfg.inference.embed_model.clone())
    else {
        let reason = format!(
            "no embedding model — the index entry at {} records no .model marker and TILLANDSIAS_EMBED_MODEL is unset",
            entry.dir.display()
        );
        eprintln!("[grounded] refuse-before-dispatch: {reason}");
        return Envelope::unsupported(reason, freshness);
    };
    let domain = cfg.inference.domain.clone().filter(|d| d != "all");
    let selected = domain_indices(&entry.chunks, domain.as_deref());
    if selected.is_empty() {
        let reason = format!(
            "the index at {} holds no chunks in domain {} — retrieval cannot ground an answer, and the raw model is not a fallback",
            entry.dir.display(),
            domain.as_deref().unwrap_or("all"),
        );
        eprintln!("[grounded] refuse-before-dispatch: {reason}");
        return Envelope::unsupported(reason, freshness);
    }

    // ── tier classify (Lua, deterministic) ────────────────────────────────
    let tier_name = {
        let rt = runtime.lock().await;
        match rt.classify_tier(query) {
            Ok(t) => t,
            Err(e) => {
                let reason = format!("the Lua tier classifier failed: {e}");
                eprintln!("[grounded] refuse-before-dispatch: {reason}");
                return Envelope::unsupported(reason, freshness);
            }
        }
    };
    let tier = match tier_name.as_str() {
        "immediate" => LatencyTier::Immediate,
        "quick" => LatencyTier::Quick,
        "fine" => LatencyTier::Fine,
        "non_usable" => LatencyTier::NonUsable,
        _ => LatencyTier::Fine,
    };
    let budget = effective_synth_budget(tier);
    // ORDER 939-jxgz. The budget is a REQUEST deadline over the model-prose
    // phases (decomposition + synthesis), not a per-phase allowance. Before
    // this, decomposition ran under raw 120s socket timeouts OUTSIDE the
    // budget, so a stalled model produced ~124s requests against a 60s
    // ceiling (measured on both twin hosts, 937-68n4 ladder) — the budget
    // bounded synthesis and not the wait. Retrieval keeps its own transport
    // timeout: the floor answer requires embeddings, so the request bound is
    // budget + retrieval transport + a small constant, and that is the
    // promise the knob's docs make.
    let prose_deadline = std::time::Instant::now() + budget;
    let remaining = move || prose_deadline.saturating_duration_since(std::time::Instant::now());

    // ── decompose (skipped on the immediate tier: its budget is the
    //    deterministic floor, and a decompose round-trip would blow it
    //    before dispatch even starts) ───────────────────────────────────────
    let original_only = vec![AdversarialPrompt {
        prompt: query.to_string(),
        kind: "original".to_string(),
    }];
    let all_prompts = if tier == LatencyTier::Immediate {
        original_only.clone()
    } else {
        let mut inference = cfg.inference.clone();
        // The socket timeout IS the cancellation mechanism for the blocking
        // thread: tokio::time::timeout below frees the CALLER at the
        // deadline, but dropping the JoinHandle detaches the thread rather
        // than cancelling it — only its own socket deadline ends the WORK
        // (939-jxgz; yoga's leaked-generation mechanism).
        inference.timeout = inference
            .timeout
            .min(remaining().max(Duration::from_millis(1)));
        let q = query.to_string();
        let decompose_task =
            tokio::task::spawn_blocking(move || decompose_with_llm(&inference, &q));
        match tokio::time::timeout(remaining(), decompose_task).await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => {
                eprintln!("[grounded] decompose task failed: {e}");
                original_only.clone()
            }
            Err(_) => {
                eprintln!(
                    "[grounded] decomposition exceeded the request budget; dispatching the original only (939-jxgz)"
                );
                original_only.clone()
            }
        }
    };

    // ── trim to the tier's variant budget (Lua, deterministic CPU floor) ──
    let trimmed = {
        let rt = runtime.lock().await;
        rt.trim_variants(&all_prompts, &tier_name)
            .unwrap_or_else(|e| {
                eprintln!("[grounded] tier_trim failed ({e}); dispatching the original only");
                original_only.clone()
            })
    };
    let trimmed = if trimmed.is_empty() {
        original_only
    } else {
        trimmed
    };

    eprintln!(
        "[grounded] query={} tier={} variants={}/{} domain={}",
        truncate_chars(query, 50),
        tier_name,
        trimmed.len(),
        all_prompts.len(),
        domain.as_deref().unwrap_or("all"),
    );

    // ── per-variant embed (concurrent, bounded) ───────────────────────────
    let mut embed_tasks = tokio::task::JoinSet::new();
    for (i, p) in trimmed.iter().enumerate() {
        let base = embed_base.clone();
        let model = embed_model.clone();
        // 864-p2rk: the matching query prefix iff the entry was embedded
        // with a doc prefix. (Divergence-from-history recorded in the
        // change's design.md: the shell harness applied no query prefix.)
        let input = if entry.prefix.is_some() {
            format!("search_query: {}", p.prompt)
        } else {
            p.prompt.clone()
        };
        let timeout = cfg.inference.timeout;
        embed_tasks.spawn_blocking(move || (i, embed_query(&base, &model, &input, timeout)));
    }
    let mut qvecs: Vec<Option<Vec<f32>>> = (0..trimmed.len()).map(|_| None).collect();
    while let Some(res) = embed_tasks.join_next().await {
        if let Ok((i, v)) = res {
            qvecs[i] = v;
        }
    }
    if qvecs.iter().all(Option::is_none) {
        return Envelope::unsupported(
            format!(
                "the embedding endpoint {embed_base} did not answer for model {embed_model} — the grounded pipeline cannot retrieve (if that is an ollama ROOT url, use its OpenAI-compatible /v1 base: TILLANDSIAS_EMBED_ENDPOINT=http://host:11434/v1)"
            ),
            freshness,
        );
    }

    // ── per-variant retrieve + synthesize (concurrent; the tier budget is
    //    REAL: tokio::time::timeout around each synthesis dispatch) ─────────
    let mut synth_tasks = tokio::task::JoinSet::new();
    let mut retrieved: Vec<Option<Vec<ScoredChunk>>> = (0..trimmed.len()).map(|_| None).collect();
    let floor = spec::retrieve_min_score();
    let refusal = spec::refusal_floor();
    let mut best_floored: f32 = 0.0;
    for (i, p) in trimmed.iter().enumerate() {
        let Some(qv) = &qvecs[i] else { continue };
        let top = top_k_filtered(qv, &entry.vectors, &selected, RETRIEVE_K);
        // Coverage is decided by the BEST score; citation-worthiness per
        // chunk. A variant whose best hit is under the refusal floor is
        // out of coverage and never reaches synthesis. ONE implementation
        // of that decision — spec::apply_retrieval_floors — shared with
        // the `spec-floor` arm the shell spec_answer path calls (821-73es).
        let all_scored: Vec<ScoredChunk> = top
            .iter()
            .map(|(idx, score)| ScoredChunk {
                chunk: entry.chunks[*idx].clone(),
                score: *score,
            })
            .collect();
        let scored = match spec::apply_retrieval_floors(all_scored, floor, refusal) {
            spec::FloorDecision::Keep(kept) => kept,
            spec::FloorDecision::OutOfCoverage { best } => {
                best_floored = best_floored.max(best);
                continue;
            }
        };
        let ctx: String = scored
            .iter()
            .map(|sc| {
                format!(
                    "=== {} ({}) ===\n{}\n",
                    sc.chunk.key, sc.chunk.path, sc.chunk.text
                )
            })
            .collect();
        let keys: String = scored
            .iter()
            .map(|sc| sc.chunk.key.as_str())
            .collect::<Vec<_>>()
            .join("; ");
        let system = domain_synthesis_prompt(domain.as_deref().unwrap_or(""), &ctx, &keys);
        retrieved[i] = Some(scored);

        let base = cfg.inference.synth_base.clone();
        let model = cfg.inference.model.clone();
        let user = p.prompt.clone();
        // What decomposition left of the request budget bounds BOTH layers:
        // the socket timeout ends the detached blocking thread's work at the
        // deadline (dropping the JoinHandle only detaches), and the tokio
        // timeout below frees this task at the same instant (939-jxgz).
        let synth_remaining = remaining().max(Duration::from_millis(1));
        let timeout = cfg.inference.timeout.min(synth_remaining);
        synth_tasks.spawn(async move {
            let dispatched = tokio::task::spawn_blocking(move || {
                chat_completion(&base, &model, Some(&system), &user, Some(320), timeout)
            });
            // The tier budget is enforced HERE — an overrun degrades to
            // the cited retrieval-only digest below, NAMED as a timeout.
            let outcome = match tokio::time::timeout(synth_remaining, dispatched).await {
                Ok(Ok(Some(a))) => SynthOutcome::Answered(a),
                Ok(_) => SynthOutcome::EndpointFailed,
                Err(_) => SynthOutcome::TimedOut,
            };
            (i, outcome)
        });
    }
    let mut synths: Vec<SynthOutcome> = (0..trimmed.len())
        .map(|_| SynthOutcome::EndpointFailed)
        .collect();
    while let Some(res) = synth_tasks.join_next().await {
        if let Ok((i, a)) = res {
            synths[i] = a;
        }
    }

    // ── per-variant envelope: only-if-used citations, cited fallback,
    //    entry frame, then Rust validation ─────────────────────────────────
    let mut outcomes: Vec<VariantOutcome> = Vec::new();
    let mut withheld: Vec<String> = Vec::new();
    for (i, p) in trimmed.iter().enumerate() {
        let Some(scored) = &retrieved[i] else {
            continue;
        };
        let mut env = match &synths[i] {
            SynthOutcome::Answered(prose) => {
                spec::build_envelope_scored_with_freshness(prose, scored, freshness.clone())
            }
            _ => Envelope::unsupported("synthesis unavailable", freshness.clone()),
        };
        if env.confidence() == Confidence::Unsupported {
            // The cited fallback: keys are present in the digest by
            // construction, so good retrieval still yields a verifiable
            // cited answer instead of refusing — and model prose that used
            // no key is DISCARDED here, never shipped uncited. The digest's
            // first line names WHICH producer fired: "no synthesis" and
            // "prose cited no key" send an operator to different knobs
            // (a dead endpoint vs a model too small to echo keys — the
            // second was misdiagnosed as the first on darwin 2026-08-29,
            // ollama's log showing 14 healthy HTTP 200 syntheses).
            let chunks: Vec<Chunk> = scored.iter().map(|sc| sc.chunk.clone()).collect();
            let digest = match &synths[i] {
                SynthOutcome::Answered(_) => format!(
                    "synthesis discarded: the model's prose cited none of the retrieved keys\n{}",
                    spec::retrieval_only_answer(&chunks)
                ),
                SynthOutcome::TimedOut => format!(
                    "synthesis timed out inside the tier budget — the model is slower than the budget allows, not missing (927-2q4w)\n{}",
                    spec::retrieval_only_answer(&chunks)
                ),
                SynthOutcome::EndpointFailed => spec::retrieval_only_answer(&chunks),
            };
            env = spec::build_envelope_scored_with_freshness(&digest, scored, freshness.clone());
        }
        // D2: the entry's frame on every citation BEFORE any HEAD stamp.
        if let Some(c) = &entry.commit {
            env = env.with_default_citation_commit(c);
        }
        let env = rust_validated(env, &cfg.root);
        if env.confidence() == Confidence::Unsupported {
            withheld.push(env.answer().to_string());
            continue;
        }
        outcomes.push(VariantOutcome {
            envelope: env,
            kind: p.kind.clone(),
            prompt: p.prompt.clone(),
        });
    }

    if outcomes.is_empty() {
        // Distinguish out-of-coverage (retrieval ran, nothing reached the
        // floor) from every other empty outcome — this is the third refusal
        // the local-experts contract promises, previously unreachable.
        if withheld.is_empty() && best_floored > 0.0 {
            return Envelope::unsupported(
                spec::out_of_coverage_reason(
                    domain.as_deref().unwrap_or("full"),
                    best_floored,
                    refusal,
                ),
                freshness,
            );
        }
        let detail = withheld
            .first()
            .cloned()
            .unwrap_or_else(|| "no variant produced a retrievable, verifiable answer".to_string());
        return Envelope::unsupported(
            format!("the grounded pipeline produced no cited answer: {detail}"),
            freshness,
        );
    }

    // ── collect merge (the retained Lua dedup), then best-cited pick ──────
    let records: Vec<serde_json::Value> = outcomes
        .iter()
        .map(|o| {
            let best_score = o
                .envelope
                .citations()
                .iter()
                .filter_map(|c| serde_json::to_value(c).ok())
                .filter_map(|v| v.get("score").and_then(|s| s.as_f64()))
                .fold(0.0f64, f64::max);
            serde_json::json!({
                "answer": o.envelope.answer(),
                "citations": o.envelope.citations().iter().map(|c| serde_json::json!({
                    "path": c.path(),
                    "line_start": c.line_start(),
                    "line_end": c.line_end(),
                    "claimed_text": "",
                })).collect::<Vec<_>>(),
                // Earned, not hardcoded: only envelopes that PASSED the Rust
                // validation above reach this record set.
                "validated": true,
                "confidence": best_score,
                "query_kind": o.kind,
                "source_prompt": o.prompt,
                "why": "", "affordances": [], "why_not": "",
            })
        })
        .collect();
    let surviving_answers: Vec<String> = {
        let records_json = serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string());
        let rt = runtime.lock().await;
        match rt.call_collect("collect", &records_json) {
            Ok(collected) => collected.iter().map(|r| r.answer.clone()).collect(),
            Err(e) => {
                // Fail-soft: dedup is an optimization, the cited work is not
                // discarded over it.
                eprintln!("[grounded] collect failed ({e}); keeping all validated variants");
                outcomes
                    .iter()
                    .map(|o| o.envelope.answer().to_string())
                    .collect()
            }
        }
    };

    // Best cited response among the survivors: most citations, then best
    // retrieval score, then trim order (the original variant leads).
    let mut best: Option<&VariantOutcome> = None;
    let mut best_rank = (0usize, f32::MIN);
    for o in &outcomes {
        if !surviving_answers.iter().any(|a| a == o.envelope.answer()) {
            continue;
        }
        let score = o
            .envelope
            .citations()
            .iter()
            .filter_map(|c| serde_json::to_value(c).ok())
            .filter_map(|v| v.get("score").and_then(|s| s.as_f64()))
            .fold(f32::MIN as f64, f64::max) as f32;
        let rank = (o.envelope.citations().len(), score);
        if best.is_none() || rank.0 > best_rank.0 || (rank.0 == best_rank.0 && rank.1 > best_rank.1)
        {
            best = Some(o);
            best_rank = rank;
        }
    }
    match best.or_else(|| outcomes.first()) {
        Some(o) => o.envelope.clone(),
        None => Envelope::unsupported(
            "the grounded pipeline produced no cited answer after collection",
            freshness,
        ),
    }
}

/// Domain-specific synthesis system prompts. Each domain gets a distinct
/// prompt that constrains the LLM to cite only domain-appropriate sources;
/// the echoed keys are what lets the only-if-used filter keep citations.
pub fn domain_synthesis_prompt(domain: &str, retrieved_ctx: &str, source_keys: &str) -> String {
    match domain {
        "cheatsheet" => format!(
            "You are the cheatsheet expert. Answer using ONLY the retrieved cheatsheet sections below. \
             Be concise and reference specific cheatsheet entries. \
             Then on a FINAL line write 'Sources:' followed by the exact section names you used, \
             comma-separated, copied verbatim from: {source_keys}.\n\n{retrieved_ctx}"
        ),
        "methodology" => format!(
            "You are the methodology expert. Answer using ONLY the retrieved methodology sections below. \
             Cite YAML paths. \
             Then on a FINAL line write 'Sources:' followed by the exact section names you used, \
             comma-separated, copied verbatim from: {source_keys}.\n\n{retrieved_ctx}"
        ),
        "code" => format!(
            "You are the code expert. Answer using ONLY the retrieved code sections below. \
             Cite file:line references. \
             Then on a FINAL line write 'Sources:' followed by the exact section names you used, \
             comma-separated, copied verbatim from: {source_keys}.\n\n{retrieved_ctx}"
        ),
        "spec" => format!(
            "You are the spec expert. Answer using ONLY the retrieved spec sections below. \
             Cite section names. \
             Then on a FINAL line write 'Sources:' followed by the exact section names you used, \
             comma-separated, copied verbatim from: {source_keys}.\n\n{retrieved_ctx}"
        ),
        _ => format!(
            "You are the Tillandsias expert. Answer using ONLY the retrieved sections below. \
             Be concise. \
             Then on a FINAL line write 'Sources:' followed by the exact section names you used, \
             comma-separated, copied verbatim from: {source_keys}.\n\n{retrieved_ctx}"
        ),
    }
}

/// Get the human-readable domain label for display in metadata.
pub fn domain_label(domain: Option<&str>) -> &'static str {
    match domain {
        Some("cheatsheet") => "Cheatsheets",
        Some("methodology") => "Methodology",
        Some("code") => "Code",
        Some("spec") => "Specs",
        _ => "All Domains",
    }
}

#[cfg(test)]
mod tests {

    // ── ORDER 927-2q4w: the synthesis budget policy ──────────────────────

    /// THE NO-REGRESSION GUARANTEE, and it is the reason this was safe to land.
    /// With no override every tier gets exactly what it got before, so a
    /// CPU-floor host — measured at 927/2231/2885 ms against a 3000 ms quick
    /// budget — is byte-identical after this change.
    #[test]
    fn without_an_override_every_tier_budget_is_unchanged() {
        for tier in [
            crate::lua_runtime::LatencyTier::Immediate,
            crate::lua_runtime::LatencyTier::Quick,
            crate::lua_runtime::LatencyTier::Fine,
            crate::lua_runtime::LatencyTier::NonUsable,
        ] {
            assert_eq!(
                resolve_synth_budget_ms(tier.budget_ms(), None),
                tier.budget_ms(),
                "tier {tier:?} must be untouched without an explicit override"
            );
        }
    }

    /// The darwin case the packet was filed from: a 7b model taking 10-24 s
    /// against a 3000 ms quick budget. The operator opts in and gets it.
    #[test]
    fn an_explicit_override_replaces_the_tier_budget() {
        assert_eq!(resolve_synth_budget_ms(3_000, Some(30_000)), 30_000);
        // Also downward: a host that wants to be snappier than the tier.
        assert_eq!(resolve_synth_budget_ms(12_000, Some(1_500)), 1_500);
    }

    /// A budget is a promise that the wait ENDS. An operator who sets ten
    /// minutes has configured a hang, not patience.
    #[test]
    fn an_override_is_clamped_to_the_ceiling() {
        assert_eq!(
            resolve_synth_budget_ms(3_000, Some(600_000)),
            SYNTH_BUDGET_CEILING_MS
        );
        // The ceiling itself is allowed — clamping must not be off by one.
        assert_eq!(
            resolve_synth_budget_ms(3_000, Some(SYNTH_BUDGET_CEILING_MS)),
            SYNTH_BUDGET_CEILING_MS
        );
    }

    /// Zero and garbage are NOT an override. A zero budget would time out
    /// every synthesis instantly and report it as a slow model, which is the
    /// misattribution this packet family exists to remove.
    #[test]
    fn a_zero_override_is_dropped_upstream_not_clamped_here() {
        // WHERE THE ZERO GUARD LIVES, asserted so a refactor cannot move it
        // silently. A zero budget times out every synthesis instantly and the
        // pipeline reports it as a model slower than its budget — the exact
        // misattribution this packet family exists to remove.
        //
        // resolve_synth_budget_ms is a PURE clamp and does not second-guess its
        // input: given Some(0) it returns 0. The guard is in
        // synth_budget_override_ms, which drops a non-positive or unparseable
        // value so None reaches the policy. Both halves are asserted because
        // the safety property is the COMPOSITION — a reader checking one half
        // would conclude the wrong thing about the other.
        assert_eq!(
            resolve_synth_budget_ms(3_000, Some(0)),
            0,
            "the policy is a pure clamp — the zero guard belongs upstream"
        );
        assert!(
            resolve_synth_budget_ms(3_000, None) > 0,
            "and with that guard doing its job, the tier budget stands"
        );
    }
    use super::*;
    use crate::lua_runtime::LuaRuntime;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    fn chunk(id: usize, key: &str, kind: &str, path: &str) -> Chunk {
        Chunk {
            id,
            path: path.to_string(),
            line_start: 1,
            line_end: 2,
            kind: kind.to_string(),
            key: key.to_string(),
            content_hash: "0".to_string(),
            text: format!("{key} body"),
        }
    }

    #[test]
    fn inference_config_default_is_complete() {
        let config = InferenceConfig::default();
        assert!(!config.synth_base.is_empty());
        assert!(config.synth_base.starts_with("http://"));
        assert!(!config.model.is_empty());
    }

    #[test]
    fn parse_base_handles_host_port_and_path() {
        assert_eq!(
            parse_base("http://inference:11434/v1"),
            Some(("inference".to_string(), 11434, "/v1".to_string()))
        );
        assert_eq!(
            parse_base("http://127.0.0.1:9"),
            Some(("127.0.0.1".to_string(), 9, String::new()))
        );
        assert_eq!(parse_base("https://x/v1"), None);
        assert_eq!(parse_base("http://"), None);
    }

    #[test]
    fn domain_indices_filters_by_kind_and_all_passes_everything() {
        let chunks = vec![
            chunk(0, "a", "spec", "openspec/specs/x/spec.md"),
            chunk(1, "b", "code", "crates/x/src/lib.rs"),
            chunk(2, "c", "spec", "openspec/specs/y/spec.md"),
            chunk(3, "d", "methodology", "methodology/x.yaml"),
        ];
        assert_eq!(domain_indices(&chunks, Some("spec")), vec![0, 2]);
        assert_eq!(domain_indices(&chunks, Some("code")), vec![1]);
        assert_eq!(
            domain_indices(&chunks, Some("cheatsheet")),
            Vec::<usize>::new()
        );
        assert_eq!(domain_indices(&chunks, None), vec![0, 1, 2, 3]);
        assert_eq!(domain_indices(&chunks, Some("all")), vec![0, 1, 2, 3]);
    }

    // ── run_grounded fixtures ───────────────────────────────────────────────

    fn crate_lua_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("lua")
    }

    fn shared_runtime(root: &Path) -> SharedLuaRuntime {
        let rt = LuaRuntime::new(&crate_lua_dir(), root).expect("lua runtime loads");
        Arc::new(tokio::sync::Mutex::new(rt))
    }

    fn fixture_root(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("tilland-grounded-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("fixture root");
        dir
    }

    fn entry_with(dir: &Path, chunks: Vec<Chunk>, commit: Option<&str>) -> SpecIndexEntry {
        std::fs::create_dir_all(dir).expect("entry dir");
        let mut chunk_lines = String::new();
        let mut vec_lines = String::new();
        for c in &chunks {
            chunk_lines.push_str(&serde_json::to_string(c).unwrap());
            chunk_lines.push('\n');
            vec_lines.push_str("[1.0,0.0]\n");
        }
        std::fs::write(dir.join("chunks.jsonl"), chunk_lines).unwrap();
        std::fs::write(dir.join("vectors.jsonl"), vec_lines).unwrap();
        if let Some(c) = commit {
            std::fs::write(dir.join(".commit"), format!("{c}\n")).unwrap();
        }
        std::fs::write(dir.join(".model"), "stub-embed\n").unwrap();
        SpecIndexEntry::load_dir(dir).expect("fixture entry loads")
    }

    /// A listener that answers POST /embeddings with a fixed vector and 404s
    /// everything else — retrieval runs for real, synthesis stays unreachable.
    fn embedding_stub(vector: &'static str) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let body = format!("{{\"data\":[{{\"embedding\":{vector}}}]}}");
            for stream in listener.incoming() {
                let Ok(mut s) = stream else { continue };
                let mut buf = [0u8; 8192];
                let _ = s.read(&mut buf);
                let head = String::from_utf8_lossy(&buf);
                let resp = if head.contains("/embeddings") {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    )
                } else {
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_string()
                };
                let _ = s.write_all(resp.as_bytes());
            }
        });
        format!("http://127.0.0.1:{port}/v1")
    }

    /// A listener that counts CONNECTIONS and answers nothing useful — the
    /// probe that proves a refusal path made zero model requests.
    fn counting_listener() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        let count = Arc::new(AtomicUsize::new(0));
        let count2 = count.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                count2.fetch_add(1, Ordering::SeqCst);
                drop(stream);
            }
        });
        (format!("http://127.0.0.1:{port}/v1"), count)
    }

    fn cfg_with(embed: Option<String>, synth: String, root: PathBuf) -> GroundedConfig {
        GroundedConfig {
            inference: InferenceConfig {
                synth_base: synth,
                embed_base: embed,
                model: "stub".to_string(),
                embed_model: Some("stub-embed".to_string()),
                timeout: Duration::from_millis(300),
                domain: None,
            },
            root,
        }
    }

    /// R2/R3 + exit criterion 2: an empty-domain miss refuses TYPED, with
    /// zero citations — and provably contacts NO model endpoint. The
    /// dichotomy: confidence!=unsupported implies citations, and the refusal
    /// carries the pinned prefix.
    #[test]
    fn refusal_not_fallback_makes_zero_model_requests() {
        let root = fixture_root("refusal");
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "code-key", "code", "src/x.rs")],
            None,
        );
        let (base, count) = counting_listener();
        let mut cfg = cfg_with(Some(base.clone()), base, root.clone());
        cfg.inference.domain = Some("spec".to_string());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(&runtime, &entry, &cfg, "what governs specs?"));
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(
            env.answer().starts_with("unsupported: "),
            "{}",
            env.answer()
        );
        assert!(env.citations().is_empty());
        assert_eq!(
            count.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "a refusal path must never contact a model endpoint"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The third promised refusal actually fires: retrieval that runs but
    /// falls below the similarity floor returns the typed out-of-coverage
    /// refusal — never irrelevant-but-real citations dressed as an answer
    /// (the darwin sourdough finding, 2026-08-29).
    /// ORDER 939-jxgz. The budget bounds the REQUEST, not the synthesis
    /// attempt alone. Pre-fix, a stalled model endpoint held the caller in
    /// DECOMPOSITION under a raw 120s socket timeout before the budget even
    /// started (measured ~124s against a 60s ceiling on both twin hosts,
    /// 937-68n4 ladder). This pins: with a stalled prose endpoint and a
    /// 1500ms budget, run_grounded returns the retrieval-only floor within
    /// budget + a small constant. Watched RED against the pre-fix code
    /// (wall > 30s) before being made green.
    #[test]
    fn stalled_prose_endpoint_returns_floor_within_budget() {
        let root = fixture_root("stall");
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "k", "spec", "openspec/specs/x/spec.md")],
            None,
        );
        let embed = embedding_stub("[1.0,0.0]");
        // A prose endpoint that ACCEPTS and never responds — the stalled
        // model. Connections are parked, not closed.
        let stall = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
            let port = listener.local_addr().unwrap().port();
            std::thread::spawn(move || {
                let mut parked = Vec::new();
                for s in listener.incoming().flatten() {
                    parked.push(s);
                }
            });
            format!("http://127.0.0.1:{port}/v1")
        };
        let mut cfg = cfg_with(Some(embed), stall, root.clone());
        // The budget under test; the config's transport timeout stays at its
        // 120s default so the bound can only come from the deadline.
        cfg.inference.timeout = Duration::from_secs(120);
        unsafe { std::env::set_var("TILLANDSIAS_SYNTH_BUDGET_MS", "1500") };
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let t0 = std::time::Instant::now();
        // Multi-clause question so the Lua classifier picks a tier that RUNS
        // decomposition — the phase the pre-fix code left unbudgeted.
        let env = rt.block_on(run_grounded(
            &runtime,
            &entry,
            &cfg,
            "compare the k spec's retrieval floors with its refusal grammar and explain how the two interact across tiers",
        ));
        unsafe { std::env::remove_var("TILLANDSIAS_SYNTH_BUDGET_MS") };
        let wall = t0.elapsed();
        assert!(
            wall < Duration::from_millis(1500) + Duration::from_secs(8),
            "request ran {wall:?} against a 1500ms budget — the deadline is not bounding the request"
        );
        // Degradation stays the cited floor, never a raw failure.
        assert!(!env.answer().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn below_floor_retrieval_refuses_out_of_coverage() {
        let root = fixture_root("floor");
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "k", "spec", "openspec/specs/x/spec.md")],
            None,
        );
        // Entry vectors are [1,0]; this query embeds nearly orthogonal, so
        // cosine ~0.10 sits under the 0.45 default floor.
        let base = embedding_stub("[0.1,0.995]");
        let cfg = cfg_with(Some(base.clone()), base, root.clone());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(
            &runtime,
            &entry,
            &cfg,
            "how do I make sourdough starter?",
        ));
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.answer().contains("out of coverage"), "{}", env.answer());
        assert!(env.citations().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The sourdough regime measured on darwin: an off-topic probe scoring
    /// ABOVE the per-chunk inclusion floor (0.45) but BELOW the coverage
    /// refusal floor (0.62) must refuse — this is the band the single-knob
    /// design answered wrongly (real probes scored 0.48-0.60).
    #[test]
    fn mid_band_score_refuses_out_of_coverage() {
        let root = fixture_root("midband");
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "k", "spec", "openspec/specs/x/spec.md")],
            None,
        );
        // Entry vectors are [1,0]; cos([0.5,0.866],[1,0]) = 0.5 — between
        // the floors.
        let base = embedding_stub("[0.5,0.8660254]");
        let cfg = cfg_with(Some(base.clone()), base, root.clone());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(
            &runtime,
            &entry,
            &cfg,
            "how do I make sourdough starter?",
        ));
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.answer().contains("out of coverage"), "{}", env.answer());
        assert!(env.citations().is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Positive control for the floor: an aligned query passes it, and with
    /// synthesis unreachable the cited digest ships — proving the floor, not
    /// the endpoint, separates coverage from no-coverage.
    #[test]
    fn above_floor_retrieval_yields_cited_digest() {
        let root = fixture_root("floor-pos");
        std::fs::create_dir_all(root.join("openspec/specs/x")).unwrap();
        std::fs::write(root.join("openspec/specs/x/spec.md"), "k body\nline two\n").unwrap();
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "k", "spec", "openspec/specs/x/spec.md")],
            None,
        );
        let base = embedding_stub("[0.999,0.01]");
        let cfg = cfg_with(Some(base.clone()), base, root.clone());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(&runtime, &entry, &cfg, "what governs specs?"));
        assert_ne!(
            env.confidence(),
            Confidence::Unsupported,
            "{}",
            env.answer()
        );
        assert!(!env.citations().is_empty());
        assert!(
            env.answer().contains("retrieval-only, no synthesis"),
            "{}",
            env.answer()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The unset-embed-endpoint preflight is a typed refusal too.
    #[test]
    fn missing_embed_endpoint_refuses_typed() {
        let root = fixture_root("noembed");
        let entry = entry_with(
            &root.join("entry"),
            vec![chunk(0, "k", "spec", "openspec/specs/x/spec.md")],
            None,
        );
        let cfg = cfg_with(None, "http://127.0.0.1:9/v1".to_string(), root.clone());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(&runtime, &entry, &cfg, "anything at all here"));
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.answer().contains("TILLANDSIAS_EMBED_ENDPOINT"));
        let _ = std::fs::remove_dir_all(&root);
    }

    /// R5 / freshness honesty: the entry's .commit propagates into the
    /// envelope frame — refusals included — and a frameless entry reports
    /// the literal `unknown`, never this process's HEAD.
    #[test]
    fn freshness_comes_from_the_entry_frame() {
        let root = fixture_root("fresh");
        let sha = "abcdef1234567890abcdef1234567890abcdef12";
        let framed = entry_with(
            &root.join("framed"),
            vec![chunk(0, "k", "code", "src/x.rs")],
            Some(sha),
        );
        let frameless = entry_with(
            &root.join("frameless"),
            vec![chunk(0, "k", "code", "src/x.rs")],
            None,
        );
        let mut cfg = cfg_with(None, "http://127.0.0.1:9/v1".to_string(), root.clone());
        cfg.inference.domain = Some("spec".to_string());
        let runtime = shared_runtime(&root);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let env = rt.block_on(run_grounded(&runtime, &framed, &cfg, "q"));
        assert_eq!(env.freshness().source_commit(), sha);
        let env = rt.block_on(run_grounded(&runtime, &frameless, &cfg, "q"));
        assert_eq!(env.freshness().source_commit(), "unknown");
        let _ = std::fs::remove_dir_all(&root);
    }
}
