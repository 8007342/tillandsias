## 1. Trivial Fixes (applied immediately)

- [x] 1.1 Fix environment-runtime spec port ranges 100→20
- [x] 1.2 Fix --bash help text to say fish not bash
- [x] 1.3 Fix runner.rs git mount: directory mount + GIT_CONFIG_GLOBAL + :ro (align with handlers.rs)
- [x] 1.4 Fix runner.rs GitHub credentials mount: add :ro
- [x] 1.5 Fix stale tray-app spec: remove contradictory GitHub Login requirement
- [x] 1.6 Add GPU passthrough to tray-mode build_run_args (was missing, only CLI had it)

## 2. CI Security (C5)

- [x] 2.1 SHA-pin all GitHub Actions in release.yml (checkout, setup-node, rust-toolchain, rust-cache, upload-artifact, download-artifact, gh-release)

## 2b. Security Findings (from security audit)

- [x] 2b.1 Remove tracked `result` file (stale Nix build artifact) + add to .gitignore
- [x] 2b.2 Escape macOS osascript command string in open_terminal() (injection via crafted dir names)
- [x] 2b.3 Add --init to short-lived gh containers in github.rs and gh-auth-login.sh (consistency)
- [x] 2b.4 Build lock is_alive() — check process name, not just PID existence (match singleton pattern)
- [ ] 2b.5 Consider flock() for atomic lock acquisition (singleton + build lock TOCTOU)

## 3. Spec Cleanup (remove aspirational/unimplemented)

- [x] 3.1 Remove WASM isolation requirement from app-lifecycle spec (F4 — no WASM in codebase, aspirational)
- [x] 3.2 Remove or demote tray icon state switching to "future" (W2/F1 — SVGs exist but icon is static)
- [x] 3.3 Remove Start/Rebuild menu actions from artifact-detection spec (F3 — never implemented)
- [x] 3.4 Clarify destroy UX in app-lifecycle: server-side delay, not hold-button (W5)

## 4. Wiring (non-trivial code changes)

- [ ] 4.1 Wire Tauri updater to show "Update available (vX.Y.Z)" in tray menu (W7)
- [x] 4.2 Extract detect_host_os() to shared module (O5 — duplicated in handlers.rs and runner.rs)

## 5. Verification

- [x] 5.1 cargo clippy + fmt clean
- [x] 5.2 cargo test passes
