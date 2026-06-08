# Step 42 — GitHub-login Vault-native flow

- **Status**: in_progress (42a + 42e/42f/42g/42h done 2026-06-08; 42a-async/42b/42c ready; 42d blocked)
- **Owner host**: linux (42d: macos+windows)
- **Branch**: linux-next
- **Depends on**: []
- **Specs**: tillandsias-vault, tray-minimal-ux, native-secrets-store
- **Audit origin**: plan/issues/github-login-vault-native-flow-2026-06-06.md,
  plan/issues/github-login-vault-lifecycle-2026-06-08.md

## Goal

Make `tillandsias --github-login` work end to end and fix the tray symptom where local
projects show but remote ones never do. Root cause: the tray derived "logged in" from host
`gh auth status` (host keyring) instead of Vault `secret/github/token`. Operator directives
extend the target: keep the token inside a container, put Vault behind HTTPS, and gate via an
idiomatic on-demand podman check (no Vault assumed running at launch).

## Tasks

- **42a `vault-flow/tray-gate-on-vault` — DONE 2026-06-06.** `vault_bootstrap::is_github_logged_in`
  (volume-guarded on-demand Vault read) replaces `tray::gh_auth_check`. Both gate sites read
  Vault. Verified: `cargo check`/`clippy -D warnings` clean under `--features tray`; 143/143
  tray tests pass.
- **42a-async `vault-flow/launch-gate-async` — ready.** Move the launch-time probe off the
  synchronous constructor path.
- **42b `vault-flow/login-in-container` — ready.** `gh auth login` + Vault write inside one
  container; fail-fast/bring-up before paste; write-capable AppRole lease.
- **42c `vault-flow/vault-https-via-ca` — ready.** Vault listener TLS via the intermediate CA;
  client trusts CA + `https://`.
- **42d `vault-flow/xplat-gating-parity` — blocked.** Wire win/mac `GithubLoginState` to the
  same Vault signal. Depends on 42a; overlaps step 36 (blocked on step 32).
- **42e `vault-flow/keyring-persistent-backend` — DONE 2026-06-08.** Root `Cargo.toml`
  `keyring` had no backend feature → mock (non-persistent) keystore → unseal key + root
  token never survived a process exit, so Vault could never be unsealed on any boot after
  the first. Enabled `async-secret-service`+`tokio`+`crypto-rust` (linux, pure-Rust zbus →
  musl-static-safe), `apple-native` (macos), `windows-native` (windows). Verified: key now
  persists (`secret-tool` lists it), re-init recovers it and unseals, musl release links
  statically with no libdbus. **Keystone fix.** Origin: lifecycle-2026-06-08 issue RC1.
- **42f `vault-flow/volume-userns-U` — DONE 2026-06-08.** `launch_vault_container` mounts the
  data volume with `:U` so podman re-chowns it to the container vault uid each launch,
  surviving userns mapping drift (Silverblue/ostree, `podman system reset`). Reproduced the
  `permission denied`/`Exited(1)` failure and verified `:U` repairs it. RC2.
- **42g `vault-flow/entrypoint-handover-tolerant` — DONE 2026-06-08.**
  `images/vault/entrypoint.sh` subsequent-boot path no longer dies on the (deliberately
  deleted) handed-over `/vault/data/root.token`; absent token ⇒ unseal-only + serve. RC3.
- **42h `vault-flow/github-login-self-heal` + env hygiene — DONE 2026-06-08.**
  `write_github_token_to_vault` brings Vault up on demand instead of erroring with the stale
  "run `--init`" hint (RC4). Separately, `tillandsias-podman::env_remove_if_present` only
  unsets podman env overrides when present → clean default-lane `running:` command (operator
  noise complaint).

## Evidence

- Symptom + cleanup + design (2026-06-06): see first audit origin issue.
- 2026-06-08 RCs + reproductions + verification: plan/issues/github-login-vault-lifecycle-2026-06-08.md.
- 42a code: `crates/tillandsias-headless/src/vault_bootstrap.rs` (is_github_logged_in,
  read_github_token_from_vault, vault_data_volume_exists), `crates/tillandsias-headless/src/tray/mod.rs`
  (gh_auth_check removed; gate at constructor + post-login refresh).
- 42e–42h code: `Cargo.toml` (keyring features), `crates/tillandsias-headless/src/vault_bootstrap.rs`
  (`:U` volume, self-heal), `images/vault/entrypoint.sh` (handover-tolerant subsequent boot),
  `crates/tillandsias-podman/src/lib.rs` (`env_remove_if_present`),
  `crates/tillandsias-headless/src/main.rs` (error hint removed).
