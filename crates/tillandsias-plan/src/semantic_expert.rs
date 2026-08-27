//! Modular semantic explanation and fallback for Tillandsias documentation & plan corpora.
//!
//! @trace spec:spec-traceability
//! @trace order:706-f7mq

use crate::answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticSection {
    pub file_rel: String,
    pub section_title: String,
    pub content: String,
    pub line_start: usize,
    pub line_end: usize,
}

pub trait SemanticSectionProvider {
    fn find_section(&self, query: &str) -> Option<SemanticSection>;
}

/// Plan markdown section provider (inspects loop_status.md, plan.yaml, etc.).
pub struct PlanSectionProvider {
    root: PathBuf,
}

impl PlanSectionProvider {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self {
            root: root.as_ref().to_path_buf(),
        }
    }

    fn scan_file_sections(&self, rel: &str) -> Vec<SemanticSection> {
        let path = self.root.join(rel);
        let raw = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };

        let mut sections = Vec::new();
        let lines: Vec<&str> = raw.lines().collect();
        let mut current_heading: Option<String> = None;
        let mut current_start: usize = 1;
        let mut current_lines: Vec<&str> = Vec::new();

        for (idx, line) in lines.iter().enumerate() {
            let line_num = idx + 1;
            if line.starts_with("## ") || line.starts_with("# ") {
                if let Some(heading) = current_heading.take() {
                    let text = current_lines.join("\n").trim().to_string();
                    if !text.is_empty() {
                        sections.push(SemanticSection {
                            file_rel: rel.to_string(),
                            section_title: heading,
                            content: text,
                            line_start: current_start,
                            line_end: if line_num > 1 { line_num - 1 } else { 1 },
                        });
                    }
                    current_lines.clear();
                }
                current_heading = Some(line.to_string());
                current_start = line_num;
            }
            if current_heading.is_some() {
                current_lines.push(line);
            }
        }

        if let Some(heading) = current_heading {
            let text = current_lines.join("\n").trim().to_string();
            if !text.is_empty() {
                sections.push(SemanticSection {
                    file_rel: rel.to_string(),
                    section_title: heading,
                    content: text,
                    line_start: current_start,
                    line_end: lines.len(),
                });
            }
        }

        sections
    }

    /// Scan a YAML file for `<key>:` and return its scalar (plain or `>`/`|`
    /// block) as a citable section. Deterministic, no YAML parser: the plan
    /// pointer surfaces are hand-maintained files whose keys appear once, and
    /// the citation must carry the REAL line span, which a parsed Value no
    /// longer knows.
    fn scan_yaml_key_block(&self, rel: &str, key: &str) -> Option<SemanticSection> {
        let path = self.root.join(rel);
        let raw = std::fs::read_to_string(&path).ok()?;
        let lines: Vec<&str> = raw.lines().collect();
        let needle = format!("{key}:");
        for (idx, line) in lines.iter().enumerate() {
            let trimmed = line.trim_start();
            let Some(after) = trimmed.strip_prefix(&needle) else {
                continue;
            };
            let indent = line.len() - trimmed.len();
            let rest = after.trim();
            let (content, line_end) =
                if rest.is_empty() || rest.starts_with('>') || rest.starts_with('|') {
                    // Block scalar: the more-indented lines that follow. Blank
                    // lines inside the block are skipped, not terminators; the
                    // span ends at the last content line.
                    let mut parts: Vec<String> = Vec::new();
                    let mut end = idx + 1;
                    for (j, follow) in lines.iter().enumerate().skip(idx + 1) {
                        if follow.trim().is_empty() {
                            continue;
                        }
                        let f_indent = follow.len() - follow.trim_start().len();
                        if f_indent <= indent {
                            break;
                        }
                        parts.push(follow.trim().to_string());
                        end = j + 1;
                    }
                    (parts.join(" "), end)
                } else {
                    (rest.trim_matches(['"', '\'']).to_string(), idx + 1)
                };
            if content.is_empty() {
                return None;
            }
            return Some(SemanticSection {
                file_rel: rel.to_string(),
                section_title: key.to_string(),
                content,
                line_start: idx + 1,
                line_end: line_end.max(idx + 1),
            });
        }
        None
    }
}

impl SemanticSectionProvider for PlanSectionProvider {
    fn find_section(&self, query: &str) -> Option<SemanticSection> {
        let lower = query.to_ascii_lowercase();

        // If the query is specifically a packet-level command or inquiry, refuse semantic fallback
        if lower.contains("status of")
            || lower.contains("packet")
            || lower.contains("order-")
            || lower.contains("blocked by")
            || lower.contains("depends on")
        {
            return None;
        }

        // Semantic fallback is intended for directional/theme/overview queries
        let is_semantic_intent = lower.contains("direction")
            || lower.contains("goal")
            || lower.contains("theme")
            || lower.contains("sprint")
            || lower.contains("active release")
            || lower.contains("overview")
            || lower.contains("focus")
            || lower.contains("milestone");

        if !is_semantic_intent {
            return None;
        }

        let files = ["plan/loop_status.md", "plan.yaml"];

        let mut all_sections = Vec::new();
        for f in files {
            all_sections.extend(self.scan_file_sections(f));
        }

        let mut best_match: Option<SemanticSection> = None;
        let mut best_score = 0;

        let query_tokens: Vec<&str> = lower
            .split_whitespace()
            .map(|t| t.trim_matches(|c: char| !c.is_alphanumeric()))
            .filter(|t| !t.is_empty())
            .collect();

        for sec in all_sections {
            let sec_lower = sec.section_title.to_ascii_lowercase();
            let mut score = 0;
            for token in &query_tokens {
                if token.len() <= 2 {
                    continue;
                }
                if sec_lower.contains(token) {
                    score += 25;
                }
                if sec.content.to_ascii_lowercase().contains(token) {
                    score += 1;
                }
            }
            if score > best_score {
                best_score = score;
                best_match = Some(sec);
            }
        }

        if best_score >= 15 {
            return best_match;
        }

        // Ratified pointer-surface fallback. The markdown scorer effectively
        // requires a HEADING hit (+25 vs +1 per content token against the 15
        // bar), and no plan markdown carries a "Direction" heading — so the
        // bootstrap's own first question ("what is the current Direction?")
        // refused for months while plan.yaml's `frontier_note` sat there
        // answering it verbatim. For direction-class queries only, fall back
        // to the designated plan.yaml current_state pointers, cited at their
        // real line span. Closed vocabulary, first non-empty key wins.
        let wants_direction = lower.contains("direction")
            || lower.contains("goal")
            || lower.contains("focus")
            || lower.contains("frontier")
            || lower.contains("theme");
        if wants_direction {
            for key in ["frontier_note", "next_step"] {
                if let Some(sec) = self.scan_yaml_key_block("plan.yaml", key) {
                    return Some(sec);
                }
            }
        }
        None
    }
}

pub struct SemanticExplainer {
    pub inference_host: String,
    pub inference_port: u16,
    pub timeout: Duration,
    pub model: String,
}

impl Default for SemanticExplainer {
    fn default() -> Self {
        let (host, port) = parse_inference_endpoint();
        Self {
            inference_host: host,
            inference_port: port,
            timeout: Duration::from_millis(1500),
            model: std::env::var("TILLANDSIAS_INFERENCE_MODEL")
                .unwrap_or_else(|_| "qwen2.5:0.5b".to_string()),
        }
    }
}

fn parse_inference_endpoint() -> (String, u16) {
    if let Ok(endpoint) = std::env::var("TILLANDSIAS_INFERENCE_ENDPOINT")
        && let Some(stripped) = endpoint.strip_prefix("http://")
    {
        if let Some((h, p)) = stripped.split_once(':')
            && let Ok(port) = p.trim_end_matches('/').parse::<u16>()
        {
            return (h.to_string(), port);
        }
        return (stripped.trim_end_matches('/').to_string(), 11434);
    }
    ("inference".to_string(), 11434)
}

impl SemanticExplainer {
    pub fn new(
        host: impl Into<String>,
        port: u16,
        timeout_ms: u64,
        model: impl Into<String>,
    ) -> Self {
        Self {
            inference_host: host.into(),
            inference_port: port,
            timeout: Duration::from_millis(timeout_ms),
            model: model.into(),
        }
    }

    /// Dispatch prompt to local Ollama inference service with bounded timeout.
    pub fn query_inference(&self, prompt: &str) -> Option<String> {
        let addr = format!("{}:{}", self.inference_host, self.inference_port);
        // Resolve HOSTNAMES, not just numeric IPs. The previous
        // `addr.parse::<SocketAddr>()` accepted only literal IPs, so the
        // default enclave DNS name `inference:11434` (and any localhost
        // spelling) short-circuited to None on EVERY call — the synthesis
        // path was dead code in both environments (order 718-nkm2's design
        // notes flagged exactly this; observed live 2026-08-15 when every
        // open-ended bare-metal query degraded to unsupported).
        let resolved = (self.inference_host.as_str(), self.inference_port)
            .to_socket_addrs()
            .ok()?;
        let mut stream = resolved
            .into_iter()
            .find_map(|a| TcpStream::connect_timeout(&a, self.timeout).ok())?;

        let _ = stream.set_read_timeout(Some(self.timeout));
        let _ = stream.set_write_timeout(Some(self.timeout));

        let body = serde_json::json!({
            "model": self.model,
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

    /// Explain query using section provider + optional inference fallback.
    pub fn explain_query<P: SemanticSectionProvider>(
        &self,
        provider: &P,
        question: &str,
        freshness: &Freshness,
    ) -> Option<Envelope> {
        let section = provider.find_section(question)?;

        let mut authority = BTreeMap::new();
        authority.insert("section".to_string(), section.section_title.clone());
        authority.insert("key".to_string(), section.section_title.clone());

        let citation = Citation::new(
            section.file_rel.clone(),
            section.line_start,
            section.line_end,
            CitationKind::Plan,
            authority,
        );

        let prompt = format!(
            "Based on this excerpt from '{}':\n\n{}\n\nQuestion: {}\nAnswer concisely:",
            section.section_title, section.content, question
        );

        let answer_text = if let Some(synthesized) = self.query_inference(&prompt) {
            let trimmed = synthesized.trim();
            if !trimmed.is_empty() {
                trimmed.to_string()
            } else {
                section.content.clone()
            }
        } else {
            section.content.clone()
        };

        Some(Envelope::supported(
            answer_text,
            vec![citation],
            Confidence::Retrieved,
            freshness.clone(),
        ))
    }

    /// Explain query using the adversarial decomposition pipeline.
    ///
    /// This is the v0.5+ path: decompose the question into adversarial
    /// variants, dispatch all concurrently to the inference endpoint, collect
    /// validated responses, and pick the best one. Consumer is unaware this
    /// happens — transparent black box producing a standard citation envelope.
    ///
    /// Falls back to the single-shot `explain_query` if the pipeline is
    /// unavailable (no Lua runtime, no inference endpoint).
    pub fn explain_query_pipeline<P: SemanticSectionProvider>(
        &self,
        provider: &P,
        question: &str,
        freshness: &Freshness,
    ) -> Option<Envelope> {
        let section = provider.find_section(question)?;

        let mut authority = BTreeMap::new();
        authority.insert("section".to_string(), section.section_title.clone());
        authority.insert("key".to_string(), section.section_title.clone());

        let citation = Citation::new(
            section.file_rel.clone(),
            section.line_start,
            section.line_end,
            CitationKind::Plan,
            authority,
        );

        let prompt = format!(
            "Based on this excerpt from '{}':\n\n{}\n\nQuestion: {}\nAnswer concisely:",
            section.section_title, section.content, question
        );

        // Try the adversarial pipeline first
        let config = crate::pipeline::InferenceConfig::default();
        let root = std::env::current_dir().unwrap_or_default();
        let lua_dir = root.join("crates").join("tillandsias-plan").join("lua");

        if let Ok(runtime) = crate::lua_runtime::LuaRuntime::new(&lua_dir, &root) {
            let shared_rt = std::sync::Arc::new(tokio::sync::Mutex::new(runtime));
            if let Ok(rt_handle) = tokio::runtime::Runtime::new()
                && let Ok((responses, _tier)) =
                    rt_handle.block_on(crate::pipeline::run_pipeline(&shared_rt, &prompt, &config))
            {
                // Pick the best response from the collected set
                if let Some(best) = responses.iter().max_by(|a, b| {
                    a.confidence
                        .partial_cmp(&b.confidence)
                        .unwrap_or(std::cmp::Ordering::Equal)
                }) && !best.answer.is_empty()
                {
                    return Some(Envelope::supported(
                        best.answer.clone(),
                        vec![citation],
                        Confidence::Retrieved,
                        freshness.clone(),
                    ));
                }
            }
        }

        // Fallback: single-shot inference (existing behavior)
        let answer_text = if let Some(synthesized) = self.query_inference(&prompt) {
            let trimmed = synthesized.trim();
            if !trimmed.is_empty() {
                trimmed.to_string()
            } else {
                section.content.clone()
            }
        } else {
            section.content.clone()
        };

        Some(Envelope::supported(
            answer_text,
            vec![citation],
            Confidence::Retrieved,
            freshness.clone(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockProvider {
        section: Option<SemanticSection>,
    }

    impl SemanticSectionProvider for MockProvider {
        fn find_section(&self, _query: &str) -> Option<SemanticSection> {
            self.section.clone()
        }
    }

    #[test]
    fn explain_query_returns_cited_envelope_on_section_match() {
        let provider = MockProvider {
            section: Some(SemanticSection {
                file_rel: "plan/loop_status.md".to_string(),
                section_title: "Direction".to_string(),
                content: "v0.5 focus is on stream observability and socket audits.".to_string(),
                line_start: 10,
                line_end: 15,
            }),
        };

        let explainer = SemanticExplainer::new("127.0.0.1", 1, 10, "qwen2.5:0.5b");
        let freshness = Freshness::new("mocksha".to_string(), "2026-08-12T00:00:00Z".to_string());
        let env = explainer
            .explain_query(&provider, "what is the current direction?", &freshness)
            .expect("should produce an envelope");

        assert_eq!(env.confidence(), Confidence::Retrieved);
        assert_eq!(env.citations().len(), 1);
        assert_eq!(env.citations()[0].path(), "plan/loop_status.md");
        assert_eq!(env.citations()[0].line_start(), 10);
        assert_eq!(env.citations()[0].line_end(), 15);
        assert!(
            env.answer()
                .contains("v0.5 focus is on stream observability")
        );
    }

    #[test]
    fn explain_query_returns_none_when_no_section_found() {
        let provider = MockProvider { section: None };
        let explainer = SemanticExplainer::new("127.0.0.1", 1, 10, "qwen2.5:0.5b");
        let freshness = Freshness::new("mocksha".to_string(), "2026-08-12T00:00:00Z".to_string());
        let env = explainer.explain_query(&provider, "nonexistent topic", &freshness);
        assert!(env.is_none());
    }

    fn fixture_root(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("tilland-sem-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("fixture dir");
        dir
    }

    #[test]
    fn direction_query_falls_back_to_plan_yaml_frontier_note() {
        let root = fixture_root("frontier");
        std::fs::write(
            root.join("plan.yaml"),
            "plan:\n  current_state:\n    frontier_note: >\n      Current product frontier is the portable cloud region path:\n      source-matching embedded guest binary and secure wire.\n    plan_index: plan/index.yaml\n",
        )
        .expect("write plan.yaml");

        let provider = PlanSectionProvider::new(&root);
        let sec = provider
            .find_section("what is the current Direction?")
            .expect("frontier_note pointer answers direction queries");
        assert_eq!(sec.file_rel, "plan.yaml");
        assert_eq!(sec.section_title, "frontier_note");
        assert!(sec.content.contains("Current product frontier"));
        assert_eq!(sec.line_start, 3);
        assert_eq!(sec.line_end, 5);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn direction_fallback_does_not_fire_for_non_direction_queries() {
        let root = fixture_root("nondir");
        std::fs::write(
            root.join("plan.yaml"),
            "plan:\n  current_state:\n    frontier_note: >\n      Current product frontier is the portable cloud region path.\n",
        )
        .expect("write plan.yaml");

        let provider = PlanSectionProvider::new(&root);
        // Semantic intent (milestone) but not direction-class: the pointer
        // fallback must not dress the frontier text up as a milestone answer.
        assert!(
            provider
                .find_section("which milestone is active?")
                .is_none()
        );
        // No semantic intent at all: unchanged refusal.
        assert!(provider.find_section("status of 394a").is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scan_yaml_key_block_handles_plain_scalars_and_missing_keys() {
        let root = fixture_root("plain");
        std::fs::write(
            root.join("plan.yaml"),
            "plan:\n  current_state:\n    next_step: \"Use the highest-impact ready packet\"\n",
        )
        .expect("write plan.yaml");

        let provider = PlanSectionProvider::new(&root);
        let sec = provider
            .scan_yaml_key_block("plan.yaml", "next_step")
            .expect("plain scalar is citable");
        assert_eq!(sec.content, "Use the highest-impact ready packet");
        assert_eq!(sec.line_start, 3);
        assert_eq!(sec.line_end, 3);
        assert!(
            provider
                .scan_yaml_key_block("plan.yaml", "absent_key")
                .is_none()
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
