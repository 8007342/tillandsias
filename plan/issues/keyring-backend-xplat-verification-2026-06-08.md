# Keyring persistent-backend cross-platform verification — 2026-06-08

trace: Cargo.toml (keyring features), plan/issues/github-login-vault-lifecycle-2026-06-08.md,
       plan/steps/42-github-login-vault-native-flow.md (42d / 42e), step 36

- **Orchestrator**: linux (`linux-next`), released v0.3.260608.4.
- **Why**: The linux fix for the Silverblue `--github-login` failure changed the **shared
  workspace `Cargo.toml`** `keyring` dependency. It previously had **no backend feature**, so
  keyring v3 silently used its in-memory **mock** keystore and nothing persisted across
  process invocations — breaking the Vault unseal-key/root-token persistence on *every*
  platform, not just Linux. The new declaration enables target-gated native backends:

  ```toml
  keyring = { version = "3", features = [
      "async-secret-service", "tokio", "crypto-rust",  # linux  (pure-Rust zbus; musl-safe)
      "apple-native",                                   # macOS  (Keychain Services)
      "windows-native",                                 # Windows (Credential Manager)
  ] }
  ```

  Linux is verified end-to-end (key persists, re-init recovers it + unseals, musl-static
  release links with no libdbus). **macOS and Windows are unverified from the linux host** —
  the `apple-native` / `windows-native` backends compile only on their own targets. These two
  packets close that gap. They are **independent of the blocked step 32** (true-rekey) and of
  each other — pure verification + a tiny fix-forward if a backend needs an extra feature.

---

## Packet `keyring-verify/macos` — owner host: **macos** (`osx-next`)

- **status**: ready
- **depends_on**: [] (decoupled from step 32 / 42d gating work)
- **owned_files**: `Cargo.toml`, `Cargo.lock`, `plan/issues/osx-next-work-queue-2026-05-25.md`,
  `plan/issues/keyring-backend-xplat-verification-2026-06-08.md` (this file — append results
  to "Results" below)
- **next_action / acceptance evidence** (record each in your checkpoint):
  1. `git fetch origin && git pull --ff-only` so `Cargo.toml` carries the new keyring features
     (the merge from main / linux-next must be present; if not, merge main first).
  2. **Builds**: the macOS tray release path compiles with `apple-native`. Run your canonical
     build (e.g. `./build.sh`-equivalent or `cargo build --release --features tray` for the
     macОS tray crate). Confirm `keyring v3` + `security-framework` compile, no missing-feature
     error. Capture the tail.
  3. **Persistence smoke** (the actual point): confirm the macOS Keychain backend persists
     across *separate* process runs. Minimal check — in two separate invocations:
     - run A: `keyring`/`Entry::new("tillandsias","verify-probe")`.set_password("ok")` (or
       reuse `vault_bootstrap` if a host build is handy);
     - run B (fresh process): `get_password()` returns `"ok"`.
     If `vault` runs on macOS, the higher-value check is: `tillandsias --init`, then in a
     second invocation confirm the unseal key is recovered from Keychain (`recovered unseal
     key from host keychain`) rather than re-derived. Either is acceptable evidence.
  4. If `apple-native` needs an extra keyring feature or a code tweak to build/persist, make
     the **minimal** fix in `Cargo.toml` (macОS-gated) and note it. Do **not** touch the
     linux/windows feature lines.
- **checkpoint**: commit to `osx-next`, push, append a dated line under "Results — macОS".
- **fallback_when_blocked**: your existing top `osx-next-work-queue` ready packet.

## Packet `keyring-verify/windows` — owner host: **windows** (`windows-next`)

- **status**: ready
- **depends_on**: []
- **owned_files**: `Cargo.toml`, `Cargo.lock`, `plan/issues/windows-next-work-queue-2026-05-25.md`,
  `plan/issues/keyring-backend-xplat-verification-2026-06-08.md` (append to "Results")
- **next_action / acceptance evidence**:
  1. `git fetch origin && git pull --ff-only` (ensure the new `Cargo.toml` keyring features are
     present; merge main if needed).
  2. **Builds**: the Windows x64 thin-tray release path compiles with `windows-native`. Run
     your canonical Windows build. Confirm `keyring v3` + the `windows` crates compile, no
     missing-feature error. Capture the tail.
  3. **Persistence smoke**: confirm the Windows Credential Manager backend persists across two
     separate process runs (same A/B `set_password`→fresh-process-`get_password` check, or the
     `--init` → second-invocation unseal-key-recovered check if vault runs on Windows).
  4. Minimal Windows-gated fix-forward in `Cargo.toml` only if needed; leave linux/macОS lines
     untouched.
- **checkpoint**: commit to `windows-next`, push, append a dated line under "Results — Windows".
- **fallback_when_blocked**: your existing top `windows-next-work-queue` ready packet.

---

## Coordination notes

- These verify a change already **live on main** (v0.3.260608.4). If a backend is broken on
  your platform, that is a release-quality finding — record it prominently and the linux
  orchestrator will cut a follow-up.
- The features are target-gated, so a broken macОS backend cannot break the linux/windows
  builds and vice-versa; you can fix-forward your own platform independently.
- Report back by appending to "Results" below and to your host work-queue; the linux
  orchestrator polls sibling branches (`git fetch` + `git log origin/osx-next origin/windows-next`).

## Results

_(append dated, host-tagged lines here)_

- 2026-06-08T17:4xZ  linux  packets shaped + pushed to osx-next/windows-next/linux-next by the
  linux orchestrator after releasing v0.3.260608.4.
