// @trace order:1437-3pj7, spec:meta-orchestration
//
// ORDER 1437-3pj7 — a session's BILLED token spend, read from the harness's
// own transcript, so the token log records a measurement instead of the 0
// every row carried since 2026-09-14.
//
// IN THE PLAN BINARY, NOT IN jq. The first cut was a jq program in
// scripts/session-tokens.sh; the 1375-tsfu ratchet refuses new jq call sites,
// and `json get`'s subset has no arithmetic, map or reduce. Summing is what
// this does, so it lives here and the script is a wrapper.
//
// ONE MESSAGE, SEVERAL LINES. The harness writes one transcript line per
// content block, each repeating the response's usage. Measured on
// tlatoanis-macbook-air 2026-09-27: 3486 assistant lines, 1519 distinct
// message ids — a naive sum overcounts 2.3x. Lines are deduplicated by
// message.id, keeping the LAST.
//
// THE FORMAT IS INTERNAL. The four usage fields are asserted on every counted
// message; a missing or non-numeric one is `schema-drift:<field>`, never a
// zero, so a format change reads as a missing instrument.

use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const USAGE_FIELDS: [&str; 4] = [
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
];

/// One transcript file, summed.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FileSum {
    /// Over every counted message.
    pub all: u64,
    /// Over messages at or after `since` (0 when there is no window).
    pub window: u64,
    /// The first counted message's model, `-` when none.
    pub model: String,
}

/// `2026-09-27T10:00:00.500Z` → `2026-09-27T10:00:00Z`: fractional seconds
/// stripped so the comparison is textual and exact (`.570Z` sorts BEFORE `Z`).
fn norm_ts(ts: &str) -> String {
    match ts.find('.') {
        Some(dot) => {
            let tail = ts[dot + 1..].trim_start_matches(|c: char| c.is_ascii_digit());
            format!("{}{}", &ts[..dot], tail)
        }
        None => ts.to_string(),
    }
}

/// Sum one JSONL transcript. `Err(field)` is schema drift.
pub fn sum_transcript(text: &str, since: Option<&str>) -> Result<FileSum, String> {
    let since = since.map(norm_ts);
    // message id → (index into `msgs`), keeping insertion order for `model`
    // and replacing the stored record so the LAST line wins.
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut msgs: Vec<Value> = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue; // a torn final line or non-JSON noise
        };
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let message = v.get("message");
        if !message
            .and_then(|m| m.get("usage"))
            .is_some_and(Value::is_object)
        {
            continue;
        }
        if message.and_then(|m| m.get("model")).and_then(Value::as_str) == Some("<synthetic>") {
            continue;
        }
        let usage = &v["message"]["usage"];
        if let Some(missing) = USAGE_FIELDS.iter().find(|f| !usage[**f].is_u64()) {
            return Err((*missing).to_string());
        }
        let key = message
            .and_then(|m| m.get("id"))
            .and_then(Value::as_str)
            .or_else(|| v.get("uuid").and_then(Value::as_str))
            .map(str::to_string)
            .unwrap_or_else(|| format!("line:{n}"));
        match index.get(&key) {
            Some(&i) => msgs[i] = v,
            None => {
                index.insert(key, msgs.len());
                msgs.push(v);
            }
        }
    }
    let tokens = |v: &Value| -> u64 {
        USAGE_FIELDS
            .iter()
            .map(|f| v["message"]["usage"][*f].as_u64().unwrap_or(0))
            .sum()
    };
    let mut sum = FileSum {
        model: msgs
            .first()
            .and_then(|v| v["message"]["model"].as_str())
            .unwrap_or("-")
            .to_string(),
        ..FileSum::default()
    };
    for v in &msgs {
        let t = tokens(v);
        sum.all += t;
        if let Some(s) = &since
            && norm_ts(v.get("timestamp").and_then(Value::as_str).unwrap_or("")) >= *s
        {
            sum.window += t;
        }
    }
    Ok(sum)
}

/// The whole answer: main transcript plus `<session>/subagents/*.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTokens {
    pub main_ctx: u64,
    pub main_ctx_cumulative: u64,
    pub subagent_tokens: u64,
    pub agents: u64,
    pub by_model: String,
    pub source: String,
}

impl SessionTokens {
    pub fn absent(source: &str) -> Self {
        SessionTokens {
            main_ctx: 0,
            main_ctx_cumulative: 0,
            subagent_tokens: 0,
            agents: 0,
            by_model: "-".to_string(),
            source: source.to_string(),
        }
    }

    pub fn line(&self) -> String {
        format!(
            "main_ctx={} main_ctx_cumulative={} subagent_tokens={} agents={} by_model={} source={}",
            self.main_ctx,
            self.main_ctx_cumulative,
            self.subagent_tokens,
            self.agents,
            self.by_model,
            self.source
        )
    }
}

/// `--transcript`, else `CLAUDE_CODE_SESSION_ID` looked up under
/// `<config>/projects/*/<id>.jsonl` — by id, not by cwd slug, because a cycle
/// often runs from a worktree whose slug differs from the session's.
pub fn resolve_transcript(
    explicit: Option<&Path>,
    session_id: Option<&str>,
    config_dir: &Path,
) -> Option<PathBuf> {
    if let Some(p) = explicit {
        return p.is_file().then(|| p.to_path_buf());
    }
    let id = session_id.filter(|s| !s.is_empty())?;
    let projects = config_dir.join("projects");
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&projects)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .collect();
    dirs.sort();
    dirs.into_iter()
        .map(|d| d.join(format!("{id}.jsonl")))
        .find(|p| p.is_file())
}

/// Measure. `since` windows `main_ctx` and the sub-agent totals; without it
/// `main_ctx` is 0 and the sub-agents are summed whole.
pub fn measure(transcript: Option<&Path>, since: Option<&str>) -> SessionTokens {
    let Some(path) = transcript else {
        return SessionTokens::absent("absent");
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return SessionTokens::absent("absent");
    };
    let main = match sum_transcript(&text, since) {
        Ok(s) => s,
        Err(field) => return SessionTokens::absent(&format!("absent:schema-drift:{field}")),
    };
    let mut out = SessionTokens {
        main_ctx: main.window,
        main_ctx_cumulative: main.all,
        subagent_tokens: 0,
        agents: 0,
        by_model: "-".to_string(),
        source: path.display().to_string(),
    };
    let subdir = path.with_extension("").join("subagents");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&subdir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    let mut models: std::collections::BTreeMap<String, u64> = Default::default();
    for f in files {
        let Ok(text) = std::fs::read_to_string(&f) else {
            continue;
        };
        let s = match sum_transcript(&text, since) {
            Ok(s) => s,
            Err(field) => return SessionTokens::absent(&format!("absent:schema-drift:{field}")),
        };
        // Per-cycle: an agent counts only when it spent inside the window (or,
        // with no window, at all).
        let n = if since.is_some() { s.window } else { s.all };
        if n == 0 {
            continue;
        }
        out.subagent_tokens += n;
        out.agents += 1;
        *models.entry(s.model).or_default() += 1;
    }
    if !models.is_empty() {
        out.by_model = models
            .iter()
            .map(|(m, c)| format!("{m}:{c}"))
            .collect::<Vec<_>>()
            .join(",");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: &str, ts: &str, model: &str, n: [u64; 4]) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","message":{{"id":"{id}","model":"{model}","usage":{{"input_tokens":{},"cache_creation_input_tokens":{},"cache_read_input_tokens":{},"output_tokens":{}}}}}}}"#,
            n[0], n[1], n[2], n[3]
        )
    }

    #[test]
    fn repeated_message_lines_count_once_and_the_window_is_exact() {
        let t = [
            rec("m1", "2026-09-27T09:00:01.100Z", "a", [1, 10, 100, 1000]),
            rec("m2", "2026-09-27T10:00:00.500Z", "a", [2, 20, 200, 2000]),
            rec("m2", "2026-09-27T10:00:00.900Z", "a", [2, 20, 200, 2000]),
            rec("m3", "2026-09-27T10:30:00.000Z", "a", [3, 30, 300, 3000]),
            "torn".to_string(),
        ]
        .join("\n");
        let s = sum_transcript(&t, Some("2026-09-27T10:00:00Z")).unwrap();
        assert_eq!((s.all, s.window), (6666, 5555));
    }

    #[test]
    fn a_missing_usage_field_is_drift_not_zero() {
        let t = r#"{"type":"assistant","message":{"id":"d","model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":1}}}"#;
        assert_eq!(
            sum_transcript(t, None).unwrap_err(),
            "cache_read_input_tokens"
        );
        assert_eq!(measure(None, None).source, "absent");
    }
}
