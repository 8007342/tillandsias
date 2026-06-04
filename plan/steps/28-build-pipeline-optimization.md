# Step 28 — Build Pipeline Optimization & Forge Lean-Up

Status: ready
Owner: multi-host
Depends on: [release-v0_3_0-readiness]

## Goal
Drastically reduce the build times for both the Tillandsias binary and the forge container image by eliminating redundant steps and pre-compiling tools.

## Tasks
- [ ] **Forge Containerfile Audit**:
    - [ ] Replace `cargo install` for `cargo-watch`, `cargo-audit`, `wasm-pack`, `trunk`, `typos-cli`, `watchexec-cli` with `curl` downloads of pre-built binaries.
    - [ ] Replace `go install` for `gopls`, `dlv`, `shfmt` with pre-built binary downloads from GitHub Releases.
    - [ ] Use `cargo-binstall --only-exec` where pre-built binary detection is reliable.
- [ ] **npm Dependency Pining**: Ensure all npm-based agents (`opencode-ai`, `@anthropic-ai/claude-code`) are pinned to stable versions or use a faster installation method (e.g., bundled assets).
- [ ] **build.sh Refactoring**: De-duplicate CI steps. Ensure `local-ci.sh` is only called once with the appropriate phase, and avoid redundant `cargo` builds when `--install` is combined with `--ci-full`.
- [ ] **Incremental Build Verification**: Verify that `init-build-state.json` correctly skips images that haven't changed, even when versions are bumped.

## Exit Criteria
- Forge image build time reduced by >50%.
- `./build.sh --ci-full --install` executes without redundant `cargo test` or `cargo build` cycles.
- All 138+ workspace tests pass in <5 minutes.
