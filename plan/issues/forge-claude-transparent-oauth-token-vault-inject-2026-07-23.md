# Transparent Claude OAuth-token capture → Vault → inject → refresh (harness-auth parity with Codex/GitHub)

- **Date:** 2026-07-23
- **Class:** implementation
- **Status:** ready
- **Area:** forge-harness-auth
- **Desired release:** near-term (v0.3/v0.4) — unblocks the Claude forge lane on all three hosts; the interactive-box smear (`forge-claude-login-url-smear-vs-device-flow-parity-2026-07-23.md`) is a live usability block.
- **Owner host:** any (shared `tillandsias-headless` login flow + `images/default/*` entrypoint/helpers; verify on macOS osx-next where the smear reproduces).
- **Governance:** changes Claude login presentation + credential handling → operator (Tlatoāni) sign-off before implementation. The design was operator-directed (2026-07-23): "the system must do everything TRANSPARENTLY … ZERO manual user steps."
- **Trace:** `spec:tillandsias-vault`, `spec:secret-rotation`
- **Depends on:** the existing Vault + AppRole-lease + proxy infra (plan order 112, `forge-harness-auth-device-flow`, completed).

## Intent

Make the Claude harness launch PRE-AUTHED inside the forge with **zero manual
user steps**, exactly like the GitHub token (`--github-login` → `secret/github/token`)
and the Codex token (`--codex-login` device flow → `secret/codex/oauth`). The
forge is an END-USER product; end users never run CLI commands. The Claude
token must be captured during the forge's OWN login stage, stored in Vault,
injected as an env var at launch, and validated/refreshed automatically.

**Root problem this closes.** Claude Code's headless/CI pre-auth consumes the
**`CLAUDE_CODE_OAUTH_TOKEN`** env — a ~1-year token minted by `claude
setup-token`. The current Claude lane instead captures the interactive
`claude auth login --claudeai` credential FILE
(`~/.claude/.credentials.json`, `provider-device-auth.sh:19-33`) and restores it
(`entrypoint-forge-claude.sh:79-84`). When that file is missing / invalid /
expired, the in-forge fallback is Claude Code's OWN interactive TUI login box
(`entrypoint-forge-claude.sh:126-139`), which smears the auth URL down the
terminal (see the parity finding). Injecting `CLAUDE_CODE_OAUTH_TOKEN` as an
env var BEFORE `claude` runs eliminates the box entirely — the smear cannot
occur because no interactive login is ever drawn.

**Correction of a prior recommendation.** An earlier draft of the parity
finding told the OPERATOR to run `claude setup-token` on their Mac. The operator
flagged that as a non-end-user action: the operator is the DEVELOPER, not the
end user. This packet implements the transparent alternative.

## The template to mirror (existing transparent flows, read-only)

- **Codex (device flow, Vault-injected end-to-end)** — the closest template:
  - CAPTURE: `images/default/codex-device-auth.sh:24-40` runs `codex login --device-auth`, then `base64 -w0 <auth.json | vault-cli.sh write-stdin secret/codex/oauth credentials_b64` (host never sees the value; stdin only).
  - STORE: `secret/codex/oauth`, field `credentials_b64` (`main.rs:6693/6758-6765`).
  - INJECT: `entrypoint-forge-codex.sh:111-113` runs `codex-oauth-vault restore` (when no `CODEX_API_KEY`) → writes `~/.codex/auth.json`.
  - REFRESH: `entrypoint-forge-codex.sh:162/168` execs through `codex-oauth-session --`, whose background `codex-oauth-vault watch` (`codex-oauth-vault.sh:49-61`) harvests refresh-token rotations back to Vault + a final harvest on exit.
- **GitHub (token, Vault-injected)** — the other transparent example:
  - CAPTURE: `run_provider_login` (`main.rs:6860`) collects the PAT and writes `secret/github/token` field `token` from inside the ephemeral `--rm` container.
  - INJECT: the forge git service reads `secret/github/token` (`main.rs:6691`, `:10910-10916`).
- **Claude (already half-transparent)** — the credential-FILE restore exists but drops to the smearing box on miss:
  - `entrypoint-forge-claude.sh:79-84` → `provider-oauth-vault restore` → `~/.claude/.credentials.json`.
  - `provider-oauth-vault.sh:22-26` (claude branch), `secret/claude/oauth` field `credentials_b64` (`main.rs:6692/6771-6778`).
  - Env-file injection precedent already in-tree: the Antigravity branch emits `export ANTIGRAVITY_TOKEN=…` for the entrypoint to eval (`provider-oauth-vault.sh:56-63`).

## Implementation steps (concrete, file:line)

### 1. CAPTURE the Claude setup-token in the login stage (mirror `codex-device-auth.sh` / `--github-login`)
- `images/default/provider-device-auth.sh` claude branch (`:19-33`): after (or instead of) `claude auth login --claudeai`, run `BROWSER=/dev/null "$BIN" setup-token` and capture the printed ~1-year token to a variable, then write it stdin-only:
  `printf '%s' "$SETUP_TOKEN" | vault-cli.sh write-stdin secret/claude/oauth-token token`
  (reuse the existing stdin-only write shape at `provider-device-auth.sh:87-88`; never place the token in argv or env).
- Probe the capability first and refuse browser/paste fallback, exactly as the `--claudeai` and `--device-auth` probes do (`provider-device-auth.sh:27-32`, `codex-device-auth.sh:24-27`). If `claude setup-token --help` is unavailable, exit non-zero with an actionable message — do NOT silently fall back.
- Rust spec: extend `CLAUDE_DEVICE_AUTH_SPEC` (`main.rs:6771-6778`) so the login lane knows about the setup-token capture (new `login_args` or a second vault field), and `run_provider_login` (`main.rs:6860`) drives it unchanged — it already mounts the AppRole lease + CA bundle and runs the `--rm` container.

### 2. Vault secret path + write
- Path: `secret/claude/oauth-token`, field `token` (a bare string, NOT base64 — it is already an opaque token, mirroring `secret/github/token`). Alternatively add a `setup_token` field to the existing `secret/claude/oauth`; prefer a separate path so the credential-FILE document and the env-token have independent lifecycles.
- Register the path in `ProviderId` mapping alongside `secret/claude/oauth` (`main.rs:6688-6733`) and in the forge Vault policy that already grants the claude lane read of `secret/claude/oauth`, so the scoped forge lease can read it at launch.
- Verify the write with a read-back (mirror `codex-device-auth.sh:42`, `provider-device-auth.sh:90`).

### 3. INJECT `CLAUDE_CODE_OAUTH_TOKEN` + `BROWSER=/dev/null` into the launch
- `images/default/provider-oauth-vault.sh` claude branch (`:22-26`): in `restore_auth`, additionally read `secret/claude/oauth-token` field `token` and emit an eval-able env file — mirror the Antigravity `ANTIGRAVITY_TOKEN` pattern (`:56-63`):
  `printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$TOKEN" > "${TILLANDSIAS_CLAUDE_TOKEN_ENV_FILE:-/tmp/claude-token.env}"; chmod 600 …`
- `images/default/entrypoint-forge-claude.sh:79-84`: after `provider-oauth-vault restore`, `[ -f /tmp/claude-token.env ] && . /tmp/claude-token.env` to set `CLAUDE_CODE_OAUTH_TOKEN` in the launch env.
- `entrypoint-forge-claude.sh:126-139` (just before the `exec … "$CC_BIN" …`): `export BROWSER=/dev/null` unconditionally in the forge (there is no browser in the headless VM; this also guarantees any residual interactive path can never spawn one).
- With `CLAUDE_CODE_OAUTH_TOKEN` set, `claude` launches pre-authed and never draws the login box.

### 4. VALIDATE + REFRESH before the ~1-year expiry
- The `codex-oauth-session` watcher (`entrypoint-forge-claude.sh:139` → `codex-oauth-session.sh:60`, `provider-oauth-vault.sh:80-92`) already harvests credential-FILE refresh-token rotations back to Vault; keep that for the `~/.claude/.credentials.json` document.
- The env-token (`CLAUDE_CODE_OAUTH_TOKEN`) is a fixed ~1-year token that does NOT auto-rotate. Add:
  - a launch-time staleness check in `ensure_provider_auth` / `provider_auth_satisfied` (`main.rs:10985-11029`) that treats a setup-token within N days of expiry as "needs re-mint" and re-runs the login lane (step 1) proactively;
  - store the mint/expiry timestamp alongside the token (a second field, or a companion `secret/claude/oauth-token-meta`) so the check is offline and does not require calling Anthropic.
- The re-mint is the ONLY recurring interactive step — at most once a year, still no browser (device/plain-URL, per step 5).

### 5. Transparent one-time interactive fallback (plain URL, no browser) ONLY when no token exists yet
- If Vault has no `secret/claude/oauth-token` (first-ever login), `provider_auth_satisfied` (`main.rs:10985`) already returns false → the tray runs the login-capable lane in the popup terminal. That lane runs `claude setup-token` with `BROWSER=/dev/null`, which presents a plain static verification URL + code ONCE (nothing to redraw → survives the Terminal.app→screen→vsock→podman PTY chain, unlike the interactive box).
- Fix the help-text mislabel while here: `main.rs:885` calls `--claudeai` a "device flow"; once the setup-token env path is primary, relabel to reflect the transparent Vault-injected token (Codex `--device-auth` is correctly labeled at `:888`).
- This is a one-time (or once-a-year) fallback, never the happy path.

## Falsifiable exit criteria

1. **Pre-authed, no box:** with a valid `secret/claude/oauth-token` in Vault, launching the Claude forge harness starts `claude` with `CLAUDE_CODE_OAUTH_TOKEN` already set and shows **no interactive login box** — the auth-URL smear cannot appear (grep the launch: `env | grep CLAUDE_CODE_OAUTH_TOKEN` non-empty before `exec claude`; the login TUI never renders).
2. **Zero manual user steps on the happy path:** a second and subsequent forge launch require no operator interaction of any kind (assert `provider_auth_satisfied(Claude)` is true → `ensure_provider_auth` does NOT spawn the login container).
3. **Host never sees the token:** the setup-token reaches Vault via stdin only; it appears in no argv, no env of the host process, and no log line (assert the write path mirrors `provider-device-auth.sh:87-88` — `write-stdin`, not an arg).
4. **Auto-refresh before expiry:** a token seeded within N days of its ~1-year expiry triggers a proactive re-mint on next launch WITHOUT the operator initiating it; a token comfortably before expiry does not.
5. **One-time fallback is plain + browserless:** with an EMPTY Vault, the login lane prints a single static URL + code (no browser spawn: `BROWSER=/dev/null`), and the captured token then satisfies criteria 1–2 on the next launch.
6. **Parity assertions hold:** unit tests mirror the Codex/GitHub shape — `ProviderId::Claude` maps the new token path; the entrypoint sources the env file; `BROWSER=/dev/null` is exported before `exec` (extend the existing `main.rs` provider-spec tests around `:14401-14417`).

## Cross-references

- `plan/issues/forge-claude-login-url-smear-vs-device-flow-parity-2026-07-23.md` — the parent finding; this packet is its PRIMARY-A. The secondary container-PTY-width fix there is independent and still wanted (it fixes EVERY in-forge TUI, not just login).
- Plan order **112** `forge-harness-auth-device-flow` (`plan/index.yaml:114-117`, completed) — the Vault + AppRole-lease + proxy substrate this reuses.
- `images/default/codex-oauth-vault.sh`, `images/default/codex-device-auth.sh`, `images/default/entrypoint-forge-codex.sh` — the Codex transparent Vault-injection template to mirror.
- `--github-login` flow: `crates/tillandsias-headless/src/main.rs` `run_provider_login` (`:6860`), `secret/github/token` (`:6691`), injection (`:10910-10916`).
- `plan/issues/research-auth-flow-state-machines-2026-07-23.md` — the login-flow FSM; capture→persist→verify→refresh here should map onto its `token_collected → token_persisted → token_verified` states, and the yearly re-mint onto a `refresh` transition.
- `plan/issues/agent-login-flows-impl-2026-06-28.md` — the original `run_provider_login` parameterization this extends.
