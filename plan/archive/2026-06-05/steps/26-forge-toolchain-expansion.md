# Step 26 — Forge Toolchain Expansion (Post-Audit)

Status: completed
Owner: linux-host
Depends on: [forge-diagnostics-improvement-loop]

## Completion (2026-06-04T01:34Z)

Both child tasks complete:
- `forge-expansion/rust-wasm` — shipped `cargo-outdated` (final approved Rust
  candidate) on the cargo-binstall batch (commit `ba3c93ce`).
- `forge-expansion/go-python` — convergence/verify-only: every approved
  Go/Python candidate is already implemented in `images/default/Containerfile`
  (Python: black, pylint, bandit, python-lsp-server, pyright, ruff;
  Go: gopls, dlv, shfmt). `flake8` is intentionally deferred (overlaps the
  shipped `pylint`). No Containerfile change required.

Verification: `./build.sh --check` PASS; instant pre-build litmus 99/99 PASS
(100% coverage). Isolation/security flags unchanged.

## Goal
Execute the approved toolchain enhancements for the default forge image, making it a "fully-loaded" development environment for Rust, Go, Python, and more, while maintaining strict isolation.

## Tasks
- [x] **Rust/Wasm Toolchain**: Add `rustup` components, `cargo-edit`, `wasm-pack`, and related dev tools to the `default` image.
- [x] **Go & Python Tooling**: Add `go`, `gopls`, `ruff`, `pyright`, and other language-specific agents as requested by the diagnostics loop.
- [x] **Dev Quality Tools**: Integrate `commitlint`, `hadolint`, and shell-script linters into the base image.
- [x] **Isolation Validation**: Run `litmus:forge-diagnostics-e2e` after each toolchain addition to ensure no privacy leaks or capability regressions.
- [x] **Prompt Refresh**: Update `plan/diagnostics/forge-diagnostics-prompt.txt` to reflect the new capabilities and remove completed audit items.

## Exit Criteria
- Forge image completeness (as reported by `/diagnose-forge`) reaches >80% for the "curated-toolchain-backlog".
- Container size remains bounded and layers are cached efficiently.
- All 138 workspace tests and 97+ litmus checks remain green.
