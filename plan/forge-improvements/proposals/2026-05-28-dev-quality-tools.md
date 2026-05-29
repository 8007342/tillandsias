---
title: Install dev quality tools (typos, just, watchexec)
gap: "missing_tools: typos, just, watchexec; CI and dev-loop automation tools absent"
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T12:15:00Z
approved_at: 2026-05-28T17:05:00Z
implemented_at: 2026-05-28T21:15:00Z
evidence: "Containerfile line 26: just via microdnf; line 55: typos-cli, watchexec-cli via cargo install"
changes:
  - file: images/default/Containerfile
    description: |
      Install typos via cargo install or prebuilt binary; install just via
      cargo install or microdnf; install watchexec via cargo install. Consider
      grouping with the Rust toolchain RUN layer since all use cargo.
  - file: images/default/entrypoint-forge-opencode.sh
    description: No changes needed (all install into ~/.cargo/bin).
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

Several developer quality-of-life tools commonly used in CI pipelines and
development workflows are absent:

- `typos` — source-code spell checker used in CI/pre-commit
- `just` — modern command runner alternative to Make
- `watchexec` — file-change watcher for dev-loop automation

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `missing_tools`: `["typos", "just", "watchexec"]`
- Stderr log confirmed `command -v typos` → `MISSING`, `command -v just` → `MISSING`, `command -v watchexec` → `MISSING`
- `proposed_enhancements` includes entries for each with rationale: used in CI pipelines, increasingly used in Rust/Python projects, foundational dev-loop tool.

## Privacy / Isolation Assessment

- All tools can be installed via `cargo install` into `~/.cargo/bin` within the forge sandbox, or via prebuilt static binaries.
- No host mounts, credentials, or network bypasses required.
- **Safe within the existing privacy/isolation envelope.**
