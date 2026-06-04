# Step 26 — Forge Toolchain Expansion (Post-Audit)

Status: ready
Owner: linux-host
Depends on: [forge-diagnostics-improvement-loop]

## Goal
Execute the approved toolchain enhancements for the default forge image, making it a "fully-loaded" development environment for Rust, Go, Python, and more, while maintaining strict isolation.

## Tasks
- [ ] **Rust/Wasm Toolchain**: Add `rustup` components, `cargo-edit`, `wasm-pack`, and related dev tools to the `default` image.
- [ ] **Go & Python Tooling**: Add `go`, `gopls`, `ruff`, `pyright`, and other language-specific agents as requested by the diagnostics loop.
- [ ] **Dev Quality Tools**: Integrate `commitlint`, `hadolint`, and shell-script linters into the base image.
- [ ] **Isolation Validation**: Run `litmus:forge-diagnostics-e2e` after each toolchain addition to ensure no privacy leaks or capability regressions.
- [ ] **Prompt Refresh**: Update `plan/diagnostics/forge-diagnostics-prompt.txt` to reflect the new capabilities and remove completed audit items.

## Exit Criteria
- Forge image completeness (as reported by `/diagnose-forge`) reaches >80% for the "curated-toolchain-backlog".
- Container size remains bounded and layers are cached efficiently.
- All 138 workspace tests and 97+ litmus checks remain green.
