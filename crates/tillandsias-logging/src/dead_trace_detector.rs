// @trace gap:OBS-005, gap:OBS-025, spec:clickable-trace-index, spec:enforce-trace-presence
//! Dead trace detection and auditing.
//!
//! This module detects `@trace` annotations in the codebase that reference specs
//! marked as "(not found)" in TRACES.md. These are "dead traces" — annotations
//! that point to non-existent or archived specs.
//!
//! Used by `scripts/audit-dead-traces.sh` for CI gate enforcement and developer remediation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::fs;
use regex::Regex;

/// A dead trace reference found in the codebase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeadTrace {
    /// The spec name that was referenced (e.g., "browser-routing-allowlist")
    pub spec_name: String,
    /// File path where the @trace annotation appears
    pub file_path: PathBuf,
    /// Line number in the file
    pub line_number: usize,
    /// The exact source line containing the annotation
    pub source_line: String,
}

impl DeadTrace {
    /// Format dead trace for human-readable output
    pub fn format_report(&self) -> String {
        format!(
            "Dead trace: @trace spec:{}\n  File: {}:{}\n  Line: {}",
            self.spec_name,
            self.file_path.display(),
            self.line_number,
            self.source_line.trim()
        )
    }
}

/// Dead trace audit results
#[derive(Debug, Clone)]
pub struct DeadTraceAudit {
    /// Map of spec_name -> list of dead traces for that spec
    pub dead_traces_by_spec: HashMap<String, Vec<DeadTrace>>,
    /// Total number of dead traces found
    pub total_dead_traces: usize,
}

impl DeadTraceAudit {
    /// Check if any dead traces were found
    pub fn has_dead_traces(&self) -> bool {
        self.total_dead_traces > 0
    }

    /// Get all dead traces sorted by spec name and line number
    pub fn all_dead_traces(&self) -> Vec<DeadTrace> {
        let mut traces: Vec<_> = self
            .dead_traces_by_spec
            .values()
            .flat_map(|v| v.iter().cloned())
            .collect();
        traces.sort_by(|a, b| {
            a.spec_name
                .cmp(&b.spec_name)
                .then_with(|| a.file_path.cmp(&b.file_path))
                .then_with(|| a.line_number.cmp(&b.line_number))
        });
        traces
    }
}

/// Parse TRACES.md and extract all dead specs (marked as "(not found)")
pub fn extract_dead_specs(traces_content: &str) -> Vec<String> {
    // Regex pattern: | `spec:name` | (not found) |
    let re = Regex::new(r"\| `spec:([^`]+)` \| \(not found\)")
        .expect("Invalid regex pattern for dead specs");

    re.captures_iter(traces_content)
        .map(|cap| cap[1].to_string())
        .collect::<Vec<_>>()
}

/// Search codebase for @trace annotations referencing dead specs
pub fn find_dead_traces(
    project_root: &Path,
    dead_specs: &[String],
) -> Result<DeadTraceAudit, String> {
    let mut dead_traces_by_spec = HashMap::new();
    let mut total_dead_traces = 0;

    // File patterns to search (same as grep in audit-dead-traces.sh)
    let searchable_extensions = [".rs", ".sh", ".md", ".toml", "Containerfile"];

    for spec_name in dead_specs {
        // Match @trace directive with spec:name anywhere in the annotation
        // Handles: @trace spec:name or @trace other spec:name or @trace spec:name, other:value
        let pattern = format!(r"@trace.*spec:{}", regex::escape(spec_name));
        let re = Regex::new(&pattern)
            .map_err(|e| format!("Invalid regex pattern: {}", e))?;

        let mut traces_for_spec = Vec::new();

        // Walk the project directory
        walk_directory(project_root, &searchable_extensions, &mut |file_path: &Path| {
            if let Ok(content) = fs::read_to_string(file_path) {
                for (line_num, line) in content.lines().enumerate() {
                    if re.is_match(line) {
                        traces_for_spec.push(DeadTrace {
                            spec_name: spec_name.clone(),
                            file_path: file_path.to_path_buf(),
                            line_number: line_num + 1,
                            source_line: line.to_string(),
                        });
                        total_dead_traces += 1;
                    }
                }
            }
        })?;

        if !traces_for_spec.is_empty() {
            dead_traces_by_spec.insert(spec_name.clone(), traces_for_spec);
        }
    }

    Ok(DeadTraceAudit {
        dead_traces_by_spec,
        total_dead_traces,
    })
}

/// Walk directory and apply callback to matching files
fn walk_directory(
    dir: &Path,
    extensions: &[&str],
    callback: &mut dyn FnMut(&Path),
) -> Result<(), String>
{
    // Skip .git, target directories
    let skip_dirs = [".git", "target", ".claude"];

    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                let file_name = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");

                // Skip certain directories
                if skip_dirs.iter().any(|skip| file_name == *skip) {
                    continue;
                }

                if path.is_dir() {
                    walk_directory(&path, extensions, callback)?;
                } else {
                    // Check file extension
                    let matches_ext = extensions.iter().any(|ext| {
                        path.to_str()
                            .map(|s| s.ends_with(ext))
                            .unwrap_or(false)
                    });

                    if matches_ext {
                        callback(&path);
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_extract_dead_specs_finds_all_dead_specs() {
        let traces_content = r#"
| Trace | Spec | Source Files |
|-------|------|--------------|
| `spec:alive-spec` | [spec.md](openspec/specs/alive-spec/spec.md) | [file.rs](src/file.rs#L1) |
| `spec:dead-spec-1` | (not found) | [file.rs](src/file.rs#L1) |
| `spec:another-alive` | [spec.md](openspec/specs/another-alive/spec.md) | [file.rs](src/file.rs#L2) |
| `spec:dead-spec-2` | (not found) | [file.rs](src/file.rs#L3) |
"#;

        let dead_specs = extract_dead_specs(traces_content);

        assert_eq!(dead_specs.len(), 2);
        assert!(dead_specs.contains(&"dead-spec-1".to_string()));
        assert!(dead_specs.contains(&"dead-spec-2".to_string()));
        assert!(!dead_specs.contains(&"alive-spec".to_string()));
        assert!(!dead_specs.contains(&"another-alive".to_string()));
    }

    #[test]
    fn test_extract_dead_specs_handles_empty_traces() {
        let traces_content = "| Trace | Spec | Source Files |\n|-------|------|--------------|";
        let dead_specs = extract_dead_specs(traces_content);
        assert_eq!(dead_specs.len(), 0);
    }

    #[test]
    fn test_find_dead_traces_detects_annotations() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let project_root = temp_dir.path();

        // Create test files with dead trace annotations
        let rs_file = project_root.join("test.rs");
        fs::write(
            &rs_file,
            "// @trace spec:dead-spec-1\nfn some_function() {}\n// @trace spec:another-dead",
        )
        .expect("Failed to write test file");

        let sh_file = project_root.join("test.sh");
        fs::write(
            &sh_file,
            "#!/bin/bash\n# @trace spec:dead-spec-1\necho hello",
        )
        .expect("Failed to write test file");

        let dead_specs = vec!["dead-spec-1".to_string(), "another-dead".to_string()];
        let audit = find_dead_traces(project_root, &dead_specs)
            .expect("Failed to audit dead traces");

        assert!(audit.has_dead_traces());
        assert_eq!(audit.total_dead_traces, 3); // Two in .rs, one in .sh

        let dead_for_spec_1 = &audit.dead_traces_by_spec["dead-spec-1"];
        assert_eq!(dead_for_spec_1.len(), 2); // One in .rs, one in .sh

        let dead_for_another = &audit.dead_traces_by_spec["another-dead"];
        assert_eq!(dead_for_another.len(), 1);
    }

    #[test]
    fn test_find_dead_traces_skips_ignored_directories() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let project_root = temp_dir.path();

        // Create file in target directory (should be skipped)
        let target_dir = project_root.join("target");
        fs::create_dir(&target_dir).expect("Failed to create target dir");
        let ignored_file = target_dir.join("file.rs");
        fs::write(
            &ignored_file,
            "// @trace spec:dead-spec\nfn some_function() {}",
        )
        .expect("Failed to write file");

        // Create file in project root (should be scanned)
        let root_file = project_root.join("file.rs");
        fs::write(&root_file, "// @trace spec:dead-spec\nfn other_function() {}")
            .expect("Failed to write file");

        let dead_specs = vec!["dead-spec".to_string()];
        let audit = find_dead_traces(project_root, &dead_specs)
            .expect("Failed to audit dead traces");

        assert_eq!(audit.total_dead_traces, 1); // Only the one in root, not in target/
    }

    #[test]
    fn test_dead_trace_format_report() {
        let trace = DeadTrace {
            spec_name: "my-spec".to_string(),
            file_path: PathBuf::from("src/file.rs"),
            line_number: 42,
            source_line: "    // @trace spec:my-spec".to_string(),
        };

        let report = trace.format_report();
        assert!(report.contains("my-spec"));
        assert!(report.contains("src/file.rs:42"));
    }

    #[test]
    fn test_audit_all_dead_traces_sorted() {
        let mut dead_traces_by_spec = HashMap::new();

        dead_traces_by_spec.insert(
            "spec-b".to_string(),
            vec![
                DeadTrace {
                    spec_name: "spec-b".to_string(),
                    file_path: PathBuf::from("b.rs"),
                    line_number: 20,
                    source_line: "// trace".to_string(),
                },
                DeadTrace {
                    spec_name: "spec-b".to_string(),
                    file_path: PathBuf::from("a.rs"),
                    line_number: 10,
                    source_line: "// trace".to_string(),
                },
            ],
        );

        dead_traces_by_spec.insert(
            "spec-a".to_string(),
            vec![DeadTrace {
                spec_name: "spec-a".to_string(),
                file_path: PathBuf::from("c.rs"),
                line_number: 5,
                source_line: "// trace".to_string(),
            }],
        );

        let audit = DeadTraceAudit {
            dead_traces_by_spec,
            total_dead_traces: 3,
        };

        let all = audit.all_dead_traces();
        assert_eq!(all.len(), 3);
        // Should be sorted: spec-a first, then spec-b
        assert_eq!(all[0].spec_name, "spec-a");
        assert_eq!(all[1].spec_name, "spec-b");
        assert_eq!(all[2].spec_name, "spec-b");
    }

    // @trace gap:OBS-025 — Additional tests for comprehensive dead trace detection coverage
    #[test]
    fn test_dead_trace_detection_with_gap_annotations() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let project_root = temp_dir.path();

        // Create file with dead trace and gap annotations on same line
        let rs_file = project_root.join("gap.rs");
        fs::write(
            &rs_file,
            "// @trace spec:dead-spec-1, gap:OBS-025\nfn func() {}",
        )
        .expect("Failed to write test file");

        let dead_specs = vec!["dead-spec-1".to_string()];
        let audit = find_dead_traces(project_root, &dead_specs)
            .expect("Failed to audit dead traces");

        assert!(audit.has_dead_traces());
        assert_eq!(audit.total_dead_traces, 1);
    }

    #[test]
    fn test_dead_trace_detection_empty_codebase() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let project_root = temp_dir.path();

        let dead_specs = vec!["nonexistent-spec".to_string()];
        let audit = find_dead_traces(project_root, &dead_specs)
            .expect("Failed to audit dead traces");

        assert!(!audit.has_dead_traces());
        assert_eq!(audit.total_dead_traces, 0);
    }

    #[test]
    fn test_extract_dead_specs_with_hyphens_and_numbers() {
        let traces_content = r#"
| `spec:cache-v2-optimization` | (not found) |
| `spec:tr-010-rapid-switch` | (not found) |
| `spec:obs-025-dead-trace-detection` | (not found) |
"#;

        let dead_specs = extract_dead_specs(traces_content);
        assert_eq!(dead_specs.len(), 3);
        assert!(dead_specs.contains(&"cache-v2-optimization".to_string()));
        assert!(dead_specs.contains(&"tr-010-rapid-switch".to_string()));
        assert!(dead_specs.contains(&"obs-025-dead-trace-detection".to_string()));
    }

    #[test]
    fn test_dead_trace_audit_no_dead_traces_in_empty_audit() {
        let audit = DeadTraceAudit {
            dead_traces_by_spec: HashMap::new(),
            total_dead_traces: 0,
        };

        assert!(!audit.has_dead_traces());
        assert_eq!(audit.all_dead_traces().len(), 0);
    }
}
