# GitHub Login menu item needs a runtime-readiness gate (cross-platform) — 2026-06-22

**Filed:** 2026-06-22 (operator directive during curl-install e2e)
**Kind:** enhancement (tray UX / state machine, all platforms)
**Status:** ready  **Owner hosts:** macos + windows + linux (shared menu_state)
**Trace:** `spec:macos-native-tray`, `spec:host-shell-architecture`,
`spec:gh-auth-script`, [[optimization-macos-vz-idiomatic-exec-layer-2026-06-21]]

## Operator requirement

The `🔑 GitHub Login` menu item must **not appear until the GitHub-login flow can
actually execute** — i.e. the runtime is provisioned and the containers the login
flow needs have been created. Showing it earlier lets the user click it before
Vault / the git container / egress network exist, which is exactly the class of
failures we hit this session (vault not up, etc.).

Readiness, per platform:

- **Linux**: a `tillandsias --init` has completed successfully and the required
  containers are up.
- **Windows / macOS**: the VM (WSL2 / Virtualization.framework) is fully built
  with Fedora 44, the latest Tillandsias release is installed (curl-install), AND
  a successful `tillandsias --init` has created the containers the login flow
  needs (Vault + git service + egress network).

So the gate is: **show GitHub Login only when (logged-out AND login-runtime-ready)**.

## Current state

`crates/tillandsias-host-shell/src/menu_state.rs::build_menu` is **auth-gated
only** (lines ~322-360): it emits exactly one of `{github-login}` (when
`GithubLoginState::LoggedOut`) OR the project body (when `LoggedIn`). There is no
runtime-readiness condition — GitHub Login shows whenever logged-out, even mid-
provision. There is already an `initial_provisioning()` menu (line ~261) and VM
phase plumbing, so a readiness signal exists to build on.

## Proposed design

1. Add a **readiness signal** to `MenuState` (e.g. `login_runtime_ready: bool`,
   or extend the existing VM/provisioning phase) meaning "init complete + the
   login-required containers exist". Source it from:
   - the in-VM headless control-wire status (it already reports `podman_ready` +
     phase; extend to "login deps ready" if needed), and/or
   - a `--init`-complete + container-presence check.
2. `build_menu`: when logged-out, emit `github-login` **only if**
   `login_runtime_ready`; otherwise emit the provisioning/"Setting up…" status
   line (no clickable login). When ready → show GitHub Login. When logged-in →
   project body (unchanged).
3. Keep it a **single shared rule** in `menu_state.rs` so macOS, Windows, and the
   Linux golden tray stay byte-for-byte aligned (the parity invariant).

## Closure (verifiable)

- Unit test on `build_menu`: logged-out + not-ready → NO `github-login` leaf (a
  provisioning line instead); logged-out + ready → `github-login` present;
  logged-in → project body. Pin the exact item sets (mirrors the existing
  `render_*` parity litmus).
- macOS AX smoke: before init completes, `assert-item "GitHub Login"` is ABSENT;
  after init + containers up, it is PRESENT.

## Notes

- Operator confirmed the rest of the logged-out menu (collapsed, version, quit)
  is correct — this packet only adds the readiness precondition to the one item.
- Pairs with the macOS Vault fix (db616e06, order 78): once login deps are
  reliably up, the readiness gate makes GitHub Login appear exactly when it will
  succeed.
