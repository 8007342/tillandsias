---
title: Install Rust toolchain (rustup, rustc, cargo)
gap: Rust compiler toolchain is missing from the forge image; CARGO_HOME and CARGO_TARGET_DIR are exported but rustc/cargo are not installed
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add rustup installation (curl-based, single-user mode) and configure default toolchain. CARGO_HOME and CARGO_TARGET_DIR are already exported by lib-common.sh.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Source cargo env if present (for rustup-managed toolchains).
approved_by: null
---

## Gap

The forge image exports `CARGO_HOME` and `CARGO_TARGET_DIR` (lines 525-526 of `lib-common.sh`) routing cargo caches to the per-project cache directory. The `forge-cache-dual` spec requires a "Cargo cache hits on second build" scenario. However, neither `rustc` nor `cargo` is installed in the image.

The `lib-common.sh` also adds `$CARGO_HOME/bin` to `$PATH` (line 561), but this directory doesn't exist at build time.

The forge-completeness-baseline audit has per-language env vars at PROMPT coverage only — but without the actual Rust toolchain, no cargo-based builds can run at all.

## Evidence

- `images/default/lib-common.sh` line 525: `export CARGO_HOME="$PROJECT_CACHE/cargo"`
- `images/default/lib-common.sh` line 526: `export CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target"`
- `images/default/lib-common.sh` line 561: `export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PNPM_HOME:$PATH"`
- `openspec/specs/forge-cache-dual/spec.md` lines 75-81: "Cargo cache hits on second build"
- `images/default/Containerfile` lines 17-24: no rust/cargo package

## Safety

- rustup.sh is fetched from the official rustup domain (sh.rustup.rs) — pinned with `-y --default-toolchain stable --no-modify-path`.
- CARGO_HOME already points to per-project cache; builds will cache there.
- Single-user install — no root daemon, no system-wide changes.
- Total ~300 MB with the standard toolchain.
