//! Modular semantic explanation and fallback for Tillandsias documentation & plan corpora.
//!
//! @trace spec:spec-traceability
//! @trace order:706-f7mq

use crate::answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
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

        if best_score >= 15 { best_match } else { None }
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
        let mut stream = TcpStream::connect_timeout(&addr.parse().ok()?, self.timeout).ok()?;

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
}
