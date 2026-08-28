//! Adversarial decomposition pipeline: LLM decompose → tier trim → concurrent
//! dispatch → CRDT collection.
//!
//! @trace order:920-pxg6
//!
//! The pipeline is the core of the expert system's hallucination reduction.
//! It takes a natural-language query, uses the LLM to decompose it into
//! adversarial variants, trims to fit the latency tier, dispatches all variants
//! concurrently to the inference endpoint, and collects the validated responses.
//!
//! Consumer is unaware this happens — it's a transparent black box that
//! produces a standard citation envelope.

use crate::lua_runtime::{AdversarialPrompt, LatencyTier, LuaRuntime, ValidatedResponse};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// A raw inference response from a single adversarial query.
#[derive(Debug, Clone)]
pub struct InferenceResponse {
    pub prompt: String,
    pub kind: String,
    pub response_text: String,
    pub success: bool,
}

/// Configuration for the inference endpoint.
#[derive(Debug, Clone)]
pub struct InferenceConfig {
    pub host: String,
    pub port: u16,
    pub model: String,
    pub timeout: Duration,
    /// Domain filter for RAG: "cheatsheet", "methodology", "code", "spec", or None.
    pub domain: Option<String>,
}

impl Default for InferenceConfig {
    fn default() -> Self {
        let host = std::env::var("TILLANDSIAS_INFERENCE_ENDPOINT")
            .ok()
            .and_then(|ep| {
                ep.strip_prefix("http://").map(|s| {
                    s.split_once(':')
                        .map(|(h, _)| h.to_string())
                        .unwrap_or(s.to_string())
                })
            })
            .unwrap_or_else(|| "127.0.0.1".to_string());
        let port = std::env::var("TILLANDSIAS_INFERENCE_ENDPOINT")
            .ok()
            .and_then(|ep| {
                ep.strip_prefix("http://")
                    .and_then(|s| s.split_once(':'))
                    .and_then(|(_, p)| p.trim_end_matches('/').parse().ok())
            })
            .unwrap_or(11434);
        let model = std::env::var("TILLANDSIAS_INFERENCE_MODEL")
            .unwrap_or_else(|_| "qwen2.5:0.5b".to_string());
        let domain = std::env::var("TILLANDSIAS_EXPERT_DOMAIN").ok();
        Self {
            host,
            port,
            model,
            timeout: Duration::from_secs(120),
            domain,
        }
    }
}

/// Send a prompt to the inference endpoint and return the raw response text.
/// Synchronous — call from `spawn_blocking`.
fn query_inference_raw(config: &InferenceConfig, prompt: &str) -> Option<String> {
    use std::io::{Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};

    let addr = format!("{}:{}", config.host, config.port);
    let resolved = (config.host.as_str(), config.port).to_socket_addrs().ok()?;
    let mut stream = resolved
        .into_iter()
        .find_map(|a| TcpStream::connect_timeout(&a, config.timeout).ok())?;

    let _ = stream.set_read_timeout(Some(config.timeout));
    let _ = stream.set_write_timeout(Some(config.timeout));

    let body = serde_json::json!({
        "model": config.model,
        "prompt": prompt,
        "stream": false
    });
    let body_str = serde_json::to_string(&body).ok()?;

    let request = format!(
        "POST /api/generate HTTP/1.1\r\n\
         Host: {}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        addr,
        body_str.len(),
        body_str
    );

    stream.write_all(request.as_bytes()).ok()?;
    let mut resp = String::new();
    stream.read_to_string(&mut resp).ok()?;

    let (_, json_part) = resp.split_once("\r\n\r\n")?;
    let parsed: serde_json::Value = serde_json::from_str(json_part).ok()?;
    parsed
        .get("response")
        .and_then(|r| r.as_str())
        .map(str::to_string)
}

/// Send a prompt to the inference endpoint as an InferenceResponse.
fn query_inference_sync(config: &InferenceConfig, prompt: &str, kind: &str) -> InferenceResponse {
    let response_text = query_inference_raw(config, prompt).unwrap_or_else(|| {
        eprintln!("[pipeline] inference returned None for kind={kind}");
        String::new()
    });
    let success = !response_text.is_empty();
    if success {
        eprintln!(
            "[pipeline] dispatch kind={kind} response_len={}",
            response_text.len()
        );
    }
    InferenceResponse {
        prompt: prompt.to_string(),
        kind: kind.to_string(),
        response_text,
        success,
    }
}

/// LLM-based decomposition: ask the model to generate adversarial variants.
///
/// This is the v0.5+ approach — the LLM itself decomposes the query into
/// components, alternatives, and adversaries. No regex, no text parsing.
/// When a domain is set, the decomposition prompt is domain-aware.
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

    let raw = match query_inference_raw(config, &decompose_prompt) {
        Some(r) => r,
        None => {
            // Fallback: use the original query as the only variant
            return vec![AdversarialPrompt {
                prompt: query.to_string(),
                kind: "original".to_string(),
            }];
        }
    };

    // Parse the LLM's JSON response
    let cleaned = raw.trim();
    // Find the JSON array in the response (may have surrounding text)
    let json_start = cleaned.find('[').unwrap_or(0);
    let json_end = cleaned.rfind(']').map(|i| i + 1).unwrap_or(cleaned.len());
    let json_str = &cleaned[json_start..json_end];

    match serde_json::from_str::<Vec<AdversarialPrompt>>(json_str) {
        Ok(prompts) if !prompts.is_empty() => prompts,
        _ => {
            // Fallback if parsing fails
            vec![AdversarialPrompt {
                prompt: query.to_string(),
                kind: "original".to_string(),
            }]
        }
    }
}

/// The full pipeline: LLM decompose → tier trim → concurrent dispatch → collect.
pub async fn run_pipeline(
    runtime: &Arc<Mutex<LuaRuntime>>,
    query: &str,
    inference_config: &InferenceConfig,
) -> Result<(Vec<ValidatedResponse>, LatencyTier), PipelineError> {
    let start = Instant::now();

    // Step 1: Classify the query tier (deterministic, fast)
    let tier_name = {
        let rt = runtime.lock().await;
        rt.classify_tier(query)
            .map_err(|e| PipelineError::DecomposeFailed(e.to_string()))?
    };
    let tier = match tier_name.as_str() {
        "immediate" => LatencyTier::Immediate,
        "quick" => LatencyTier::Quick,
        "fine" => LatencyTier::Fine,
        "non_usable" => LatencyTier::NonUsable,
        _ => LatencyTier::Fine,
    };

    // Step 2: LLM-based decomposition (the model generates adversarial variants)
    let decompose_start = Instant::now();
    let all_prompts = {
        let config = inference_config.clone();
        let query_owned = query.to_string();
        tokio::task::spawn_blocking(move || decompose_with_llm(&config, &query_owned))
            .await
            .unwrap_or_else(|e| {
                eprintln!("[pipeline] decompose task failed: {e}");
                vec![AdversarialPrompt {
                    prompt: query.to_string(),
                    kind: "original".to_string(),
                }]
            })
    };

    // Step 3: Trim variants to fit the tier budget (deterministic)
    let trimmed = {
        let rt = runtime.lock().await;
        rt.trim_variants(&all_prompts, &tier_name)
            .map_err(|e| PipelineError::DecomposeFailed(e.to_string()))?
    };

    eprintln!(
        "[pipeline] query={} tier={} variants={}/{} ({}ms decompose)",
        &query[..query.len().min(50)],
        tier_name,
        trimmed.len(),
        all_prompts.len(),
        decompose_start.elapsed().as_millis()
    );

    // Step 4: Concurrent dispatch — send all variants in parallel
    let dispatch_start = Instant::now();
    let mut handles = Vec::new();

    for prompt in &trimmed {
        let config = inference_config.clone();
        let prompt_text = prompt.prompt.clone();
        let kind = prompt.kind.clone();

        let handle =
            tokio::task::spawn_blocking(move || query_inference_sync(&config, &prompt_text, &kind));
        handles.push(handle);
    }

    let mut inference_responses = Vec::new();
    for handle in handles {
        match handle.await {
            Ok(resp) => inference_responses.push(resp),
            Err(e) => {
                eprintln!("[pipeline] dispatch task failed: {e}");
            }
        }
    }

    eprintln!(
        "[pipeline] dispatch completed: {}/{} succeeded ({}ms)",
        inference_responses.iter().filter(|r| r.success).count(),
        inference_responses.len(),
        dispatch_start.elapsed().as_millis()
    );

    // Step 5: Collect via CRDT (deduplication, all validated responses kept)
    let collect_start = Instant::now();

    let responses_for_lua: Vec<serde_json::Value> = inference_responses
        .iter()
        .filter(|r| r.success)
        .map(|r| {
            serde_json::json!({
                "answer": r.response_text,
                "citations": [],
                "confidence": 0.5,
                "validated": true,
                "query_kind": r.kind,
                "source_prompt": r.prompt,
                "why": "",
                "affordances": [],
                "why_not": "",
            })
        })
        .collect();

    let responses_json = serde_json::to_string(&responses_for_lua)
        .map_err(|e| PipelineError::CollectFailed(e.to_string()))?;

    let collected = {
        let rt = runtime.lock().await;
        rt.call_collect("collect", &responses_json)
            .map_err(|e| PipelineError::CollectFailed(e.to_string()))?
    };

    eprintln!(
        "[pipeline] collected {} responses ({}ms collect, {}ms total)",
        collected.len(),
        collect_start.elapsed().as_millis(),
        start.elapsed().as_millis()
    );

    Ok((collected, tier))
}

#[derive(Debug)]
pub enum PipelineError {
    DecomposeFailed(String),
    CollectFailed(String),
}

impl std::fmt::Display for PipelineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PipelineError::DecomposeFailed(msg) => write!(f, "decompose failed: {msg}"),
            PipelineError::CollectFailed(msg) => write!(f, "collect failed: {msg}"),
        }
    }
}

impl std::error::Error for PipelineError {}

/// Domain-specific synthesis system prompts. Each domain gets a distinct prompt
/// that constrains the LLM to cite only domain-appropriate sources.
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
    use super::*;

    #[test]
    fn inference_config_defaults_from_env() {
        let config = InferenceConfig::default();
        assert!(!config.host.is_empty());
        assert!(config.port > 0);
        assert!(!config.model.is_empty());
    }
}
