# Step 28 — Build Pipeline Optimization & Forge Lean-Up

Status: completed
Owner: multi-host
Depends on: [release-v0_3_0-readiness]

## Goal
Drastically reduce the build times for both the Tillandsias binary and the forge container image by eliminating redundant steps and pre-compiling tools.

## Tasks
- [x] **Forge Containerfile Audit**:
    - [x] Replace `cargo install` for `cargo-watch`, `cargo-audit`, `wasm-pack`, `trunk`, `typos-cli`, `watchexec-cli` with `cargo-binstall --disable-strategies compile` to fetch precompiled binaries.
    - [x] Replaced `go install` for `gopls` with system-level package `gopls` via `microdnf`.
    - [x] Replaced `go install` for `dlv` and `shfmt` with pre-built binary downloads from GitHub Releases.
    - Completed in `b37cad93`: container image builds successfully, packages/binaries downloaded directly instead of compiling from source.
- [x] **npm Dependency Pining**: Managed in the base image layering.
- [x] **build.sh Refactoring**: De-duplicate CI steps. Ensure `local-ci.sh` is only called once with the appropriate phase, and avoid redundant `cargo` builds when `--install` is combined with `--ci-full`.
    - Completed in `4db56b6e`: one pre-build `local-ci.sh` dispatch, direct post-build/runtime litmus phases, no install-to-debug-build fallthrough, and evidence reuse instead of repeated Cargo/litmus runs.
    - Evidence: `./build.sh --check` PASS; instant pre-build litmus `101/101` PASS across `87/87` active specs; `dev-build` instant litmus `2/2` PASS.
- [x] **Incremental Build Verification**: Confirmed skips on unchanged images.

## Exit Criteria
- [x] Forge image build time reduced by >50%.
- [x] `./build.sh --ci-full --install` executes without redundant `cargo test` or `cargo build` cycles.
- [x] All 138+ workspace tests pass in <5 minutes.

## Verification Evidence
- Modified `Containerfile` to use `cargo-binstall --disable-strategies compile`, GitHub release binaries for Delve and `shfmt`, and `gopls` system packages.
- Ran `./build.sh --ci-full` successfully: 14/14 checks passed, 122 litmus tests passed, CentiColon dashboard regenerated.
- Code formatted with `cargo fmt --all`.
