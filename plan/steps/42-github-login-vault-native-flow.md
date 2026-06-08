# Step 42 — GitHub-login Vault-native flow

- **Status**: in_progress (42a done; 42a-async/42b/42c ready; 42d blocked)
- **Owner host**: linux (42d: macos+windows)
- **Branch**: linux-next
- **Depends on**: []
- **Specs**: tillandsias-vault, tray-minimal-ux, native-secrets-store
- **Audit origin**: plan/issues/github-login-vault-native-flow-2026-06-06.md

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

## Evidence

- Symptom + cleanup + design: see audit origin issue.
- 42a code: `crates/tillandsias-headless/src/vault_bootstrap.rs` (is_github_logged_in,
  read_github_token_from_vault, vault_data_volume_exists), `crates/tillandsias-headless/src/tray/mod.rs`
  (gh_auth_check removed; gate at constructor + post-login refresh).
