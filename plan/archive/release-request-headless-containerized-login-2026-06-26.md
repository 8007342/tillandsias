# Release Request: headless containerized-login + download-retry fixes

**Filed by:** `macos-advance-20260626T2230Z` on 2026-06-26
**Branch:** `osx-next` (commits pending push after this file)
**Requires action from:** Linux worker (merge → main → release)

## Summary

Four fixes are ready on `osx-next` that require a new Linux headless release to
be testable end-to-end on macOS:

1. **Containerized GitHub login** (`crates/tillandsias-headless/src/main.rs`)
   — removed bare-guest `gh auth login --with-token` and `gh auth setup-git`
   (~48 lines). The vault write, container gh auth login, and container gh auth
   status all remain. This enforces the architecture invariant: only
   `tillandsias-headless` and `podman` run on the bare guest.

2. **Vault keyring noise** (`crates/tillandsias-headless/src/vault_bootstrap.rs`)
   — downgraded WARNING to "note" when keyring is unavailable in the VM guest.

3. **Download retry + idle timeout** (`crates/tillandsias-vm-layer/src/fetch.rs`)
   — `resp.chunk().await` wrapped with 30s `tokio::time::timeout`; on stall or
   chunk error retries up to 5× with exponential backoff using Range resume.
   Benefits both macOS VzRuntime and Windows WslRuntime.

4. **macOS `--opencode` CLI** (`crates/tillandsias-macos-tray/src/`)
   — new `exec_over_stream_with_input_streaming` (vsock_exec.rs),
   `opencode_main` (diagnose.rs), and `--opencode <path> [--prompt <text>]`
   dispatch (main.rs). macOS-only, builds locally; no new headless code.

## Verification

- `cargo check --workspace` — clean ✓
- `cargo test -p tillandsias-vm-layer` — 23 passed ✓
- `cargo test -p tillandsias-headless --bin tillandsias` — 90 passed ✓
- `cargo build --release -p tillandsias-macos-tray` — built ✓

## What's blocked until release

- `--github-login` exit_code:0 (headless fix in items 1+2 above)
- `--opencode . --prompt "Use the /meta-orchestration skill"` live test
  (needs working `--github-login` first for vault token)

## Work Packet: release-request/headless-containerized-login

- id: `release-request/headless-containerized-login`
- owner_host: linux
- capability_tags: [rust, release, headless, ci]
- status: ready
- next_action: >
    Merge osx-next into linux-next (after ff-pull check), run CI, cut a new
    release. The two headless crate changes (main.rs bare-guest gh removal,
    vault_bootstrap.rs WARNING downgrade) need the musl cross-compile only the
    Linux worker can do. The vm-layer change (fetch.rs) and the macos-tray changes
    are already built locally on macOS but also benefit from a release tag.
- events:
  - type: discovered
    ts: "2026-06-26T22:30:00Z"
    agent_id: "macos-advance-20260626T2230Z"
    host: macos
