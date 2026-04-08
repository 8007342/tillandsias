# Proposal: Add Missing @trace Annotations

## Problem

A methodology audit found that 6 Rust source files have zero `@trace` annotations despite implementing specs that exist. This breaks the bidirectional link between specs and implementation that OpenSpec requires for monotonic convergence.

## Solution

Add `@trace spec:<name>` annotations to the 6 untraced files at module-level doc comments and key entry points (1-3 traces per file). Two files from the original audit list (`build_lock.rs`, `embedded.rs`) already had traces. Two others (`machine.rs`, `web.rs`) no longer exist in the codebase.

## Files and Specs

| File | Spec(s) | Traces Added |
|------|---------|--------------|
| `src-tauri/src/update_cli.rs` | `update-system` | 3 (module, `run()`, `apply_update()`) |
| `crates/tillandsias-podman/src/events.rs` | `podman-orchestration` | 2 (module, `stream()`) |
| `src-tauri/src/cleanup.rs` | `cli-mode` | 3 (module, `run_stats()`, `run_clean()`) |
| `src-tauri/src/updater.rs` | `update-system` | 3 (module, `spawn_update_tasks()`, `install_update()`) |
| `src-tauri/src/singleton.rs` | `singleton-guard` | 2 (module, `try_acquire()`) |
| `src-tauri/src/github.rs` | `remote-projects`, `gh-auth-script` | 3 (module, `fetch_repos()`, `clone_repo()`) |

## Already Traced (no changes needed)

| File | Existing Traces |
|------|----------------|
| `src-tauri/src/build_lock.rs` | `spec:build-lock` (2 traces) |
| `src-tauri/src/embedded.rs` | `spec:embedded-scripts`, `spec:default-image`, `spec:proxy-container`, `spec:git-mirror-service`, `spec:inference-container` (8+ traces) |

## Does Not Exist

- `crates/tillandsias-podman/src/machine.rs` -- not found in codebase
- `src-tauri/src/web.rs` -- not found in codebase
