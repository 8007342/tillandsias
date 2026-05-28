---
title: Install Rust toolchain (rustc, cargo, rust-analyzer, clippy, rustfmt, cargo-*)
gap: "missing_tools: rustc, cargo, rust-analyzer, clippy, rustfmt, cargo-nextest, cargo-chef, cargo-audit, cargo-watch"
category: sdk
status: proposed
proposed_at: 2026-05-28T12:15:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Add rustup-init installation step (curl + sh), install stable toolchain
      with rustc, cargo, rust-analyzer, clippy, rustfmt components, then install
      cargo-nextest, cargo-chef, cargo-audit, cargo-watch via cargo install.
      Set RUSTUP_HOME and prepend ~/.cargo/bin to PATH.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Export RUSTUP_HOME and ensure ~/.cargo/bin is in PATH.
approval_required: orchestrator
approved_by:
---

## Gap

CARGO_HOME is already pre-configured to `/home/forge/.cache/tillandsias-project/cargo` in the forge image env,
but `rustc`, `cargo`, and the entire Rust toolchain are absent from the image.

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `missing_tools`: `["rustc", "cargo", "rust-analyzer", "clippy", "rustfmt", "cargo-nextest", "cargo-chef", "cargo-audit", "cargo-watch"]`
- Stderr log confirmed `command -v rustc` → `MISSING`, `command -v cargo` → `MISSING`
- `command -v rustfmt` → `MISSING`, `command -v clippy-driver` → `MISSING`
- `command -v cargo-nextest` → `MISSING`, `command -v cargo-chef` → `MISSING`,
  `command -v cargo-audit` → `MISSING`, `command -v cargo-watch` → `MISSING`
- `command -v rust-analyzer` → `MISSING`

## Privacy / Isolation Assessment

- Rust toolchain installs entirely within the forge user's home (`~/.cargo`, `~/.rustup`).
- All compilation happens in the existing tmpfs-backed `/tmp` and cache under `CARGO_HOME`.
- No external network access beyond the proxy — `cargo` uses the same `http_proxy` env already set.
- No host credentials or sockets exposed.
- **Safe within the existing privacy/isolation envelope.**
