# GitHub-login ⇄ Vault lifecycle failures — 2026-06-08

trace: openspec/specs/tillandsias-vault/spec.md, native-secrets-store,
       plan/index.yaml (steps 32, 42), plan/issues/github-login-vault-native-flow-2026-06-06.md

- **Host / branch**: linux (`linux-next`)
- **Origin**: operator report 2026-06-08 on a fresh Fedora Silverblue host running
  the curl-installed release `v0.3.260608.3`. `tillandsias --github-login` accepted a
  pasted token (gh auth succeeded, "Logged in as 8007342") but then failed with
  `Error: vault write failed: Vault container is not running. Run \`tillandsias --init\``,
  **even though `--init` had been run and succeeded**. The operator also flagged the long
  `env -u …` override chain printed before every podman command as finicky and asked that
  the default runtime carry no overrides.

This note is **intake/report only** per the markdown-distillation policy. Durable
architecture lives in the cited specs; the actionable work is shaped in `plan/index.yaml`
step 42 (tasks 42e–42h added this cycle) and overlaps step 32 (vault key hardening).

---

## Root causes (all reproduced + fixed + verified on the linux host)

The single operator symptom decomposed into **four** layered defects. They compound: any
one of them leaves Vault down at `--github-login` time, and the first three made a Vault
relaunch on an existing data volume impossible.

### RC1 — keyring crate had NO backend → host secrets were never persisted (keystone)

`keyring = "3"` was declared with **no platform feature**. In keyring v3 that silently
selects the **in-memory mock keystore**: `set_password`/`get_password` appear to succeed
but persist nothing across process invocations. Consequence, host-independent:

- the Vault unseal key and its installation anchor were re-derived on every invocation
  (a fresh random anchor each time → a **different** unseal key each time), so an existing
  volume's envelope could never be decoded and Vault could never be unsealed on any boot
  after the first;
- the root-token handover into the "keychain" was lost the moment the process exited.

This is why `--init` worked exactly once (fresh volume → first boot → init+unseal in one
process), and why Vault could never come back afterwards.

**Fix:** enable a persistent, platform-native backend (root `Cargo.toml`). Linux uses
`async-secret-service` (pure-Rust `zbus`, not the `libdbus-sys` C bindings the sync backend
needs) so the **musl-static release stays self-contained** — verified the release binary is
still `statically linked` with no libdbus. macOS `apple-native`, Windows `windows-native`
(target-gated; only the host backend compiles).

### RC2 — Vault data volume hit userns ownership drift → "permission denied"

`launch_vault_container` mounted the named volume as `tillandsias-vault-data:/vault/data`
with **no `:U`**. Under rootless podman, a userns id-mapping shift between launches — which
Fedora Silverblue/ostree updates and `podman system reset` routinely cause — left
`/vault/data` owned by a uid the in-container `vault` user could no longer write. Vault
died on boot with `storage migration check error: open /vault/data/core/_migration:
permission denied` → `FATAL: vault API never came up`.

**Reproduced** by `podman unshare chown -R 0:0` of the volume → container `Exited (1)`.
**Fix:** mount with `:U` so podman re-chowns the volume to the container user on every
launch. Verified: drifted volume + `:U` → `HEALTHY+UNSEALED`.

### RC3 — entrypoint subsequent-boot path died on the handed-over root token

`images/vault/entrypoint.sh` subsequent-boot branch ran
`ROOT_TOKEN="$(cat /vault/data/root.token)"` under `set -euo pipefail`. But the host's
one-time handover **deletes** `/vault/data/root.token` after first boot, so every relaunch
on an existing volume aborted with `cat: /vault/data/root.token: No such file`.

**Fix:** tolerate the absent (already-handed-over) root token; when it is absent the server
is already unsealed and fully provisioned from persistent storage, so skip the
token-authenticated re-provisioning and go straight to serving. (Aligns with step 32's
direction of not persisting the root token.)

### RC4 — `--github-login` did not self-heal and printed a misleading hint

The Vault running-check sat at the end of `run_github_login`, *after* the interactive paste,
and on failure told the operator to run `--init` (which they had already done). 

**Fix:** `write_github_token_to_vault` now brings Vault up on demand via the same idempotent
`ensure_vault_running` that `--init` uses, instead of erroring; the stale "run `--init`"
hint is removed.

### Bonus — env-override noise (operator's second complaint)

Every podman invocation was prefixed with an unconditional
`env -u CONTAINER_CONNECTION -u CONTAINER_HOST -u LD_LIBRARY_PATH -u LD_PRELOAD
-u TILLANDSIAS_PODMAN_*` chain. In the default desktop-user-session lane **none** of those
variables are set, so the removals were no-ops that only cluttered the `running:` log and
implied the runtime depends on a pile of overrides.

**Fix:** `env_remove_if_present` in `tillandsias-podman` only unsets a variable when it is
actually present. Behaviour-preserving; the default-lane command is now a clean
`"/usr/bin/podman" "run" …` with zero `env -u`. Verified: `grep -c 'env -u'` → 0.

---

## Verification (linux host, debug binary + musl release)

Full lifecycle, end to end:

1. fresh `--init` → unseal key derived **and persisted** (`secret-tool search service
   tillandsias` now lists `vault-root-token-v1@tillandsias`); Vault healthy.
2. kill container + `chown -R 0:0` the volume (simulated userns drift).
3. re-`--init` → `recovered unseal key from host keychain (v1)` → `:U` repairs ownership →
   entrypoint tolerates the absent root token → `vault healthy (sealed=false)`,
   `running=true`. **This is the path that was previously impossible.**
4. `--github-login` `running:` line is clean (0 `env -u`).

Builds: `cargo clippy --workspace --features tray -- -D warnings` clean; musl-static release
(`--target x86_64-unknown-linux-musl --features tray`) links and the binary is
`statically linked` (no libdbus). 142 podman+headless lib unit tests pass. (The two
`signal_handling` integration tests fail identically on a clean tree — pre-existing,
environmental, unrelated.)

---

## Per-host queue impact

- **linux**: RC1–RC4 + env hygiene landed and verified linux-side (step 42 tasks 42e–42h).
- **macos + windows**: the RC1 `Cargo.toml` change enables `apple-native` / `windows-native`
  (target-gated; they compile only on their host). Sibling owners (`osx-next`,
  `windows-next`) should **verify their release build links with the new keyring backend and
  that the platform keychain actually persists the unseal key + root token across runs**.
  This is the cross-platform parity tail of step 42 (was 42d) and overlaps step 36 (Vault
  keychain parity, blocked on step 32). Flagged here for pickup; not blocking the linux
  release.
