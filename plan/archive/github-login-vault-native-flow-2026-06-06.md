# GitHub-login Vault-native flow — 2026-06-06

trace: openspec/specs/tillandsias-vault/spec.md, openspec/specs/tray-minimal-ux,
       plan/index.yaml (steps 32, 42, 43), plan/issues/pre-vault-obsolescence-audit-2026-06-05.md

- **Host / branch**: linux (`linux-next`)
- **Origin**: operator report 2026-06-06 — `tillandsias --github-login` failed with
  `vault write failed: Vault container is not running`, and the tray kept listing local
  projects while never showing remote ones. Live debugging by the orchestrator confirmed
  the root causes below and removed the stale host credential.

This note is **intake/report only** per the markdown-distillation policy. The actionable
work is shaped into `plan/index.yaml` steps 42 (the flow) and 43 (the Quit hang). Durable
architecture lives in the cited specs, not here.

---

## 1. What was wrong (verified)

The pre-Vault audit (2026-06-05) declared the `--github-login` core flow "sound" but never
examined the **tray's auth-gating source of truth**. That is the actual cause of the
operator's symptom.

- **RC1 — Vault not running.** There is no `tillandsias-vault` container and no
  `tillandsias-vault-data` volume on the host; `--init` was never completed. The Vault
  running-check sits at the *end* of `run_github_login` (`main.rs:3383`), so the token is
  captured in a throwaway `--rm` container and then discarded when the write fails.
- **RC2 — tray gated on the wrong source (the real bug).** `tray/mod.rs` derived
  `is_authenticated` from **host `gh auth status`** (`gh_auth_check()`), i.e. the host
  keyring — *not* Vault `secret/github/token`. So with a stale host token present, the tray
  thought it was authenticated → built local+cloud submenus → cloud read from (absent) Vault
  → "local shows, remote doesn't." Worse, a *successful* Vault login (which logs into a
  container, never host gh) would never flip the gate, so login never "stuck."
- **RC3 — `--github-login` checks Vault too late.** The running-check is after the
  interactive paste, wasting the token instead of failing fast / self-healing.
- **Cleanup done 2026-06-06.** The legacy host credential — two Secret-Service entries under
  `service=gh:github.com` (username `8007342` and empty) plus the `hosts.yml` pointer — was
  purged. `service=tillandsias` (Vault unseal key) was untouched (empty; Vault never inited).

## 2. Operator directives (target architecture)

1. **Token never leaves a container.** Run `gh auth login` *and* the Vault write inside one
   container (the git image already carries both `gh` and `vault-cli`), so the token is never
   read into the host `tillandsias` process. Needs a write-capable AppRole/policy lease for
   the login op (today only the read-only `git-mirror` policy touches `secret/github/token`).
2. **Vault over HTTPS, not plaintext.** `images/vault/vault.hcl` is `tls_disable = "true"` on
   `0.0.0.0:8200`. Put Vault behind a cert issued by the existing intermediate CA
   (`/tmp/tillandsias-ca/intermediate.{crt,key}`, generated in `main.rs:1159-1309`; already
   used by Squid SSL-bump and mounted into the router). Client must add the CA as a root and
   speak `https://`.
3. **No running Vault at launch — gate via idiomatic podman.** The tray must answer
   "is_logged_in" by consulting Vault on demand through the `tillandsias-podman` layer, not by
   assuming a persistent Vault or reading host gh.
4. **Tray UX:** secret missing → show only `🔑 GitHub Login`, hide local projects (the
   existing `else` branch already renders this; it was just fed the wrong boolean).

## 3. What landed this cycle (step 42a)

Gate the tray on Vault, not host gh:
- New `vault_bootstrap::is_github_logged_in(debug)` — true iff a non-empty
  `secret/github/token` is retrievable. Guarded by `vault_data_volume_exists()` so a
  never-logged-in host (no volume) answers `false` instantly with **no** Vault bring-up;
  otherwise `ensure_vault_running` (on-demand) + read-back. Helper
  `read_github_token_from_vault` mirrors the write-path read-back.
- `tray/mod.rs`: removed `gh_auth_check()` (host `gh auth status`); both gate sites
  (launch constructor + post-login refresh) now call `is_github_logged_in`.
- Verified: `cargo check`/`clippy -D warnings` clean (`--features tray`), 143/143 tray
  tests pass.
- **Follow-up (42a-async):** the launch-time gate calls `ensure_vault_running` synchronously
  in the constructor; bounded in practice (volume ⇒ image already built ⇒ ~seconds, same
  order as the old 5s gh check) but the worst case is the 60s health timeout. Make the
  launch probe async (default logged-out, background recheck + revision bump).

## 4. What remains (steps 42b/42c/42d)

- **42b** login-in-container direct-to-Vault write; `run_github_login` fails fast / brings
  Vault up first; token never transits the host. Add a write-capable AppRole lease + policy.
- **42c** Vault HTTPS via the intermediate CA (vault.hcl listener TLS, cert mount, client
  `add_root_certificate` + `https://`, health checks/probes to https).
- **42d** cross-platform follow-on: wire `host-shell` `GithubLoginState` (win/mac trays) to
  the same Vault `is_logged_in` signal — today it is only set in `menu_disabled_v2.rs` +
  tests, not from a live Vault read. Depends on 42a landing as the reference.

## 5. Per-host queue impact

- **linux**: 42a done; 42b/42c next (linux-owned).
- **macos + windows**: 42d (gating parity) depends on 42a; **step 36** (Vault keychain +
  vsock/HvSocket unseal-key parity) remains `blocked` on **step 32**. No win/mac work is
  unblocked yet — the unlock order is `step 32 → 42a (done) → 36 + 42d`. Do not start remote
  agents until step 32 lands.
