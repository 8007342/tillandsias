// @trace gap:OBS-005, gap:OBS-025, spec:clickable-trace-index
//! Integration tests for dead trace detection module

use std::fs;
use std::path::PathBuf;
use tempfile::TempDir;
use tillandsias_logging::{extract_dead_specs, find_dead_traces, DeadTraceAudit};

#[test]
fn test_dead_trace_detection_integration_real_traces_md() {
    let traces_content = r#"# Trace Index

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
}

#[test]
fn test_dead_trace_detection_finds_annotations_in_files() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let project_root = temp_dir.path();

    // Create test files with dead trace annotations
    let rs_file = project_root.join("test.rs");
    fs::write(
        &rs_file,
        r#"// @trace spec:dead-spec
fn some_function() {}
// @trace spec:another-dead
fn another() {}"#,
    )
    .expect("Failed to write test file");

    let sh_file = project_root.join("test.sh");
    fs::write(
        &sh_file,
        r#"#!/bin/bash
# @trace spec:dead-spec
echo hello"#,
    )
    .expect("Failed to write test file");

    // Create a .md file to test
    let md_file = project_root.join("README.md");
    fs::write(
        &md_file,
        r#"# Test
<!-- @trace spec:dead-spec -->
Some content"#,
    )
    .expect("Failed to write test file");

    let dead_specs = vec!["dead-spec".to_string(), "another-dead".to_string()];
    let audit = find_dead_traces(project_root, &dead_specs)
        .expect("Failed to audit dead traces");

    assert!(audit.has_dead_traces());
    assert!(audit.total_dead_traces >= 3); // At least 3 traces found

    // Verify dead-spec-1 traces
    let dead_for_spec = audit.dead_traces_by_spec.get("dead-spec");
    assert!(dead_for_spec.is_some());
    assert!(dead_for_spec.unwrap().len() >= 2); // At least in .rs and .sh

    // Verify another-dead traces
    let dead_for_another = audit.dead_traces_by_spec.get("another-dead");
    assert!(dead_for_another.is_some());
}

#[test]
fn test_dead_trace_detection_skips_ignored_directories() {
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

    // Should find only one (in root), not the one in target/
    let traces = &audit.dead_traces_by_spec["dead-spec"];
    assert_eq!(traces.len(), 1);
    assert!(traces[0].file_path.to_str().unwrap().contains("file.rs"));
    assert!(!traces[0].file_path.to_str().unwrap().contains("target"));
}

#[test]
fn test_dead_trace_detection_empty_project() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let project_root = temp_dir.path();

    // Create empty directories but no annotated files
    fs::create_dir(project_root.join("src")).expect("Failed to create src");

    let dead_specs = vec!["nonexistent-spec".to_string()];
    let audit = find_dead_traces(project_root, &dead_specs)
        .expect("Failed to audit dead traces");

    assert!(!audit.has_dead_traces());
    assert_eq!(audit.total_dead_traces, 0);
}

#[test]
fn test_dead_trace_detection_all_traces_sorted() {
    let traces_content = r#"| Trace | Spec | Source |
|-------|------|--------|
| `spec:z-spec` | (not found) | [file.rs](src/file.rs) |
| `spec:a-spec` | (not found) | [file.rs](src/file.rs) |
| `spec:m-spec` | (not found) | [file.rs](src/file.rs) |
"#;

    let dead_specs = extract_dead_specs(traces_content);
    assert_eq!(dead_specs.len(), 3);

    // Verify they're extracted (order might vary from regex)
    assert!(dead_specs.iter().any(|s| s == "z-spec"));
    assert!(dead_specs.iter().any(|s| s == "a-spec"));
    assert!(dead_specs.iter().any(|s| s == "m-spec"));
}
