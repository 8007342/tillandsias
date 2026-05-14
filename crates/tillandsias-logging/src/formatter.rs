// @trace spec:runtime-logging
use serde_json::Value;
use std::fmt::Write;

/// Format log entry as compact text suitable for terminal or file output.
///
/// Format: `TIMESTAMP LEVEL component: message {key=val, ...}`
///
/// For accountability events, adds multi-line block with metadata.
pub fn format_compact(
    timestamp: &str,
    level: &str,
    component: &str,
    message: &str,
    context: &Option<std::collections::HashMap<String, Value>>,
    spec_trace: &Option<String>,
    accountability: &Option<bool>,
    category: &Option<String>,
    safety: &Option<String>,
    use_color: bool,
) -> String {
    let mut output = String::new();

    let level_str = if use_color {
        match level {
            "TRACE" => "\x1b[36mTRACE\x1b[0m", // cyan
            "DEBUG" => "\x1b[34mDEBUG\x1b[0m", // blue
            "INFO" => "\x1b[32mINFO\x1b[0m",   // green
            "WARN" => "\x1b[33mWARN\x1b[0m",   // yellow
            "ERROR" => "\x1b[31mERROR\x1b[0m", // red
            _ => level,
        }
    } else {
        level
    };

    // Main log line
    let _ = write!(output, "{} {} {}: {}", timestamp, level_str, component, message);

    // Add context fields (filtered to exclude accountability metadata)
    if let Some(ctx) = context {
        let filtered: Vec<_> = ctx
            .iter()
            .filter(|(k, _)| {
                !matches!(
                    k.as_str(),
                    "accountability" | "category" | "safety" | "spec"
                )
            })
            .collect();

        if !filtered.is_empty() {
            let _ = write!(output, " {{");
            for (i, (k, v)) in filtered.iter().enumerate() {
                let _ = write!(output, "{}={}", k, format_value(v));
                if i < filtered.len() - 1 {
                    let _ = write!(output, ", ");
                }
            }
            let _ = write!(output, "}}");
        }
    }

    // Add accountability metadata if present
    if accountability.unwrap_or(false) {
        let _ = write!(output, "\n");
        if let Some(cat) = category {
            let _ = write!(output, "  [{}]", cat);
        }

        if let Some(note) = safety {
            let _ = write!(output, "\n  -> safety note: {}", note);
        }

        if let Some(spec) = spec_trace {
            let spec_name = extract_spec_name(spec);
            let search_url = format!(
                "https://github.com/8007342/tillandsias/search?q=%40trace+spec%3A{}",
                spec_name
            );
            let _ = write!(output, "\n  @trace {}: {}", spec_name, search_url);
        }
    }

    output
}

/// Extract spec name from "spec:<name>" format
fn extract_spec_name(spec: &str) -> &str {
    spec.strip_prefix("spec:").unwrap_or(spec)
}

/// Format a JSON value compactly
fn format_value(v: &Value) -> String {
    match v {
        Value::String(s) => format!("\"{}\"", s),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        Value::Array(_) | Value::Object(_) => v.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::HashMap;

    #[test]
    fn test_format_compact_basic() {
        let output = format_compact(
            "2026-05-14T12:34:56Z",
            "INFO",
            "proxy",
            "cache hit",
            &None,
            &None,
            &None,
            &None,
            &None,
            false,
        );
        assert!(output.contains("2026-05-14T12:34:56Z"));
        assert!(output.contains("INFO"));
        assert!(output.contains("proxy"));
        assert!(output.contains("cache hit"));
    }

    #[test]
    fn test_format_with_context() {
        let mut ctx = HashMap::new();
        ctx.insert("url".to_string(), json!("api.github.com"));
        ctx.insert("size".to_string(), json!(1024));

        let output = format_compact(
            "2026-05-14T12:34:56Z",
            "INFO",
            "proxy",
            "request",
            &Some(ctx),
            &None,
            &None,
            &None,
            &None,
            false,
        );

        assert!(output.contains("url="));
        assert!(output.contains("size=1024"));
    }

    #[test]
    fn test_format_accountability_event() {
        let output = format_compact(
            "2026-05-14T12:34:56Z",
            "WARN",
            "git-service",
            "push failed",
            &None,
            &Some("spec:git-mirror-service".to_string()),
            &Some(true),
            &Some("git".to_string()),
            &Some("credentials not exposed".to_string()),
            false,
        );

        assert!(output.contains("[git]"));
        assert!(output.contains("safety note"));
        assert!(output.contains("git-mirror-service"));
    }

    #[test]
    fn test_filter_accountability_fields() {
        let mut ctx = HashMap::new();
        ctx.insert("container".to_string(), json!("forge-1"));
        ctx.insert("accountability".to_string(), json!(true));
        ctx.insert("category".to_string(), json!("secrets"));

        let output = format_compact(
            "2026-05-14T12:34:56Z",
            "INFO",
            "core",
            "event",
            &Some(ctx),
            &None,
            &None,
            &None,
            &None,
            false,
        );

        assert!(output.contains("container="));
        assert!(!output.contains("accountability="));
        assert!(!output.contains("category="));
    }
}
