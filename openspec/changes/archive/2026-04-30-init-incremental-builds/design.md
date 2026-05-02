## Context

The `tillandsias --init` command builds all container images (proxy, forge, git, inference) in sequence. Currently, if a build fails, re-running `--init` rebuilds everything from scratch, wasting time. The build script (`scripts/build-image.sh`) already has staleness detection via hash files, but the init command doesn't track which images were successfully built across runs.

Additionally, the `--debug` flag is only available in `CliMode::Attach` (project attach mode), not in init mode. Users need debug output to troubleshoot init failures.

## Goals / Non-Goals

**Goals:**
- Track successful image builds across `--init` runs using a state file
- Skip already-successful images on re-run (incremental rebuilds)
- Support `--debug` flag in `--init` mode to capture build logs
- Display `tail -10` of failed build logs at end of `--init --debug` run
- Add `@trace spec:init-incremental-builds` annotations

**Non-Goals:**
- Changing the staleness detection in `build-image.sh` (already works correctly)
- Modifying image build logic (still uses `build-image.sh`)
- Adding interactive retry prompts (failures are reported, user re-runs manually)

## Decisions

### Decision 1: State file format and location

**Choice**: JSON file at `$HOME/.cache/tillandsias/init-build-state.json`

**Rationale**: JSON is human-readable and easily parsed. Location aligns with existing cache dir used by `build-image.sh` for hash files. Using a single state file (not per-image files) simplifies cleanup and reading.

**Format**:
```json
{
  "version": "0.1.97.76",
  "last_run": "2026-04-30T10:30:00Z",
  "images": {
    "proxy": {"status": "success", "tag": "tillandsias-proxy:v0.1.97.76"},
    "forge": {"status": "failed", "tag": "tillandsias-forge:v0.1.97.76", "log": "/tmp/tillandsias-init-proxy.log"}
  }
}
```

**Alternatives considered**:
- Per-image state files (like hash files) → More files to manage, no benefit
- TOML format → Would need `toml` crate or manual parsing; JSON is simpler

### Decision 2: Debug log capture approach

**Choice**: In debug mode, have Rust spawn `build-image.sh` with output piped through `tee` to capture logs while still showing output on terminal.

**Rationale**: `tee` preserves real-time output to terminal AND writes to log file. This is simpler than implementing custom pipe handling in Rust.

**Implementation**:
```rust
// In init.rs, when debug=true:
let log_file = format!("/tmp/tillandsias-init-{image_name}.log");
let cmd = format!("{} {} --tag {} --backend {} 2>&1 | tee {}", 
    script.display(), image_name, tag, backend, log_file);
std::process::Command::new("bash").arg("-c").arg(&cmd)...
```

**Alternatives considered**:
- Modify `build-image.sh` to add `--log-file` flag → More invasive, shell script gets more complex
- Use Rust `Stdio::piped()` and manually duplicate output → Loses real-time progress bars from `podman build`

### Decision 3: When to update state file

**Choice**: Update state file after EACH image build (not at end of all builds).

**Rationale**: If the init process is interrupted (Ctrl+C, crash), already-completed images are still marked as success in the state file. This enables true incremental resumes.

**Implementation**: Use a helper function `update_build_state(image, status, log_path)` that reads, modifies, and writes the state file atomically (write to temp, rename).

### Decision 4: How to propagate `--debug` to `CliMode::Init`

**Choice**: Add `debug: bool` field to `CliMode::Init` variant.

**Rationale**: Consistent with `CliMode::Attach` which already has a `debug` field. The `parse()` function in `cli.rs` already scans for `--debug` but only applies it to Attach mode. We'll extend it to also apply to Init mode.

**Code change in `cli.rs`**:
```rust
// In parse(), where --init is handled:
if args.iter().any(|a| a == "--init") {
    let force = args.iter().any(|a| a == "--force");
    let debug = args.iter().any(|a| a == "--debug");
    return Some((CliMode::Init { force, debug }, log_config));
}
```

## Risks / Trade-offs

**[Risk] State file becomes stale if user manually deletes images** → Mitigation: Before skipping an image, verify it actually exists in podman (`podman image exists`). If not, rebuild regardless of state.

**[Risk] JSON state file corruption (crash during write)** → Mitigation: Write to temp file first, then atomic rename. Use `serde_json` for parsing with fallback to empty state on parse error.

**[Risk] Debug log files accumulate in /tmp** → Mitigation: Clean up old log files at start of each init run (keep only current run's logs). Mention in cheatsheet.

**[Risk] Race condition if two --init runs execute simultaneously** → Mitigation: Existing `build_lock.rs` already prevents concurrent builds of the same image. State file is updated per-image after lock acquisition, so race is limited to state file writes. Acceptable for a CLI tool.
