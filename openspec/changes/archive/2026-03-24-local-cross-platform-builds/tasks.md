## 1. CI Fixes (release workflow + Node.js 24)

- [x] 1.1 Fix tag validation in `release.yml` — add `workflow_dispatch` input for `version`, resolve version from tag or input
- [x] 1.2 Add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` env var to `release.yml` at workflow level
- [x] 1.3 Add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` env var to `ci.yml` at workflow level
- [x] 1.4 Bump `setup-node` `node-version` from `22` to `24` in `release.yml`
- [x] 1.5 Verify CI workflow runs cleanly (trigger `ci.yml` via `workflow_dispatch`) — requires push first

## 2. Windows Cross-Compilation Script

- [x] 2.1 Create `build-windows.sh` with flag parsing matching `build.sh` conventions (`--release`, `--test`, `--check`, `--clean`, `--help`, `--toolbox-reset`)
- [x] 2.2 Implement `tillandsias-windows` toolbox auto-creation with deps (clang, lld, nsis, cargo-xwin, rust target `x86_64-pc-windows-msvc`)
- [x] 2.3 Implement debug build: `cargo xwin build --workspace --target x86_64-pc-windows-msvc`
- [x] 2.4 Implement release build: `cargo xwin build --release --target x86_64-pc-windows-msvc` with Tauri NSIS bundling
- [x] 2.5 Implement `--check` and `--test` modes (cross-check and cross-compile tests)
- [x] 2.6 Add Microsoft SDK license notice on first cargo-xwin download
- [x] 2.7 Add unsigned artifact warning on release build completion
- [x] 2.8 Test: run `./build-windows.sh --check` to verify cross-compilation toolchain works

## 3. Documentation

- [x] 3.1 Create `docs/cross-platform-builds.md` — explain CI-first strategy, Windows cross-compilation with limitations, macOS infeasibility with legal rationale
- [x] 3.2 Update CLAUDE.md build commands section to include `build-windows.sh` usage
