---
title: Install WASM toolchain (wasm-pack, trunk)
gap: "missing_tools: wasm-pack, trunk; project genus uses WASM/Rust"
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T12:15:00Z
approved_at: 2026-05-28T17:05:00Z
implemented_at: 2026-05-28T21:15:00Z
evidence: "Containerfile line 55: wasm-pack, trunk installed via cargo install"
changes:
  - file: images/default/Containerfile
    description: |
      After Rust toolchain is installed, add `cargo install wasm-pack trunk`
      or install via prebuilt binaries (wasm-pack from GitHub releases, trunk
      via cargo install).
  - file: images/default/entrypoint-forge-opencode.sh
    description: No changes needed (cargo-installed binaries land in ~/.cargo/bin).
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

The project genus is `tillandsias` which uses WASM/Rust. `wasm-pack` (build tool)
and `trunk` (WASM bundler/dev-server) are absent.

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `missing_tools`: `["wasm-pack", "trunk"]`
- Stderr log confirmed `command -v wasm-pack` → `MISSING`, `command -v trunk` → `MISSING`
- `proposed_enhancements` includes: `{"tool": "wasm-pack+trunk", "ecosystem": "wasm", "why": "Project genus is 'tillandsias' which uses WASM/Rust. wasm-pack and trunk enable the WASM development workflow end-to-end."}`

## Privacy / Isolation Assessment

- Installed via `cargo install` into `~/.cargo/bin` within the forge sandbox.
- wasm-pack downloads prebuilt binaries for wasm-bindgen etc. via the proxy.
- All build artifacts in existing cache mounts.
- **Safe within the existing privacy/isolation envelope.**
