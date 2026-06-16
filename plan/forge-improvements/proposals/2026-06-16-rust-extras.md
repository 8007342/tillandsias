---
title: Install Rust extras (cargo-udeps, lldb-mi, markdownlint-cli2)
gap: "missing_tools: cargo-udeps, lldb-mi, markdownlint-cli2 — Rust unused-deps analysis, debugger IDE interface, doc linting"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install cargo-udeps (cargo install), lldb-mi (microdnf lldb),
      markdownlint-cli2 (npm install -g). Add to existing Rust/npm layers.
---

## Gap

Diagnostics (`diagnostics_20260614T150524Z-summary.md`) report these Rust
ecosystem gaps:

- **cargo-udeps**: Detects unused Rust dependencies in Cargo.toml
- **lldb-mi**: LLDB machine interface for Rust IDE debugging
- **markdownlint-cli2**: Modern markdown linting CLI

## Privacy/Isolation Assessment

- cargo-udeps: cargo install — same envelope as existing Rust tooling
- lldb-mi: microdnf package — same envelope as existing gdb/lldb
- markdownlint-cli2: npm install — same envelope as existing node/npm
- **Safe within the existing privacy/isolation envelope**
