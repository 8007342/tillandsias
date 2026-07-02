# Research: Agent Login Flows (--claude-login / --codex-login / --antigravity-login)

**Status:** `done` (operator decision recorded 2026-07-01 — see Verdict)
**Owner:** linux
**Date:** 2026-06-28 (resolved 2026-07-01)
**Kind:** research
**Trace:** `spec:tillandsias-vault`, `spec:secret-rotation`, `spec:forge-as-only-runtime`

---

## VERDICT — operator decision 2026-07-01

**Support both auth models, on different tracks:**

- **OAuth (subscription) — the login flows, NOW.** `--claude-login`,
  `--codex-login`, `--antigravity-login` are **OAuth/subscription** flows. The
  rationale: a cheaper subscription (Claude Pro/Max, ChatGPT Plus, Google) is
  enough for **interactive** forge sessions, which is what an operator drives by
  hand. So the three named login subcommands persist an **OAuth token set**, not
  an API key.
- **API keys — autonomous work, LATER.** API keys remain the credential for
  **autonomous / unattended** forge runs (higher/again-metered quota, no
  interactive token refresh). The API-key *storage* plumbing already exists
  (`ProviderId` + `secret/<provider>/api-key` + `read/write_provider_api_key`,
  order 112) and autonomous forges already consume it. A dedicated API-key
  **entry flow** (paste-into-container, mirroring `--github-login`) is deferred
  to `plan/issues/agent-api-key-login-flows-2026-07-01.md` (plan order 143).

Net: this packet's `run_provider_login` and the impl packet (order 132) scope to
the **OAuth device-code / OOB** path. API-key entry is a separate later packet;
the two share `ProviderId` and the containerized-boundary machinery.

### Per-service verdict (OAuth track)

| Service (subcommand) | OAuth identity provider | Vault secret | Autonomous fallback (later) |
|---|---|---|---|
| `--claude-login` (Claude Code) | Claude.ai / console.anthropic.com (Pro/Max subscription) | `secret/anthropic/oauth` | `secret/anthropic/api-key` (exists) |
| `--codex-login` (Codex) | ChatGPT sign-in (auth.openai.com) | `secret/openai/oauth` | `secret/openai/api-key` (exists) |
| `--antigravity-login` (Antigravity) | Google account (accounts.google.com) | `secret/gemini/oauth` | `secret/gemini/api-key` (exists) |

### Vault OAuth schema (new — resolves Question 3 for the OAuth track)

`secret/<provider>/oauth` (KV v2), host never reads it:

```
access_token   : string   # short-lived bearer
refresh_token  : string   # long-lived; re-mints access_token
expiry         : rfc3339  # access_token expiry (for pre-session refresh)
obtained_at    : rfc3339
scope          : string   # granted scopes, for audit
```

A `refresh_provider_oauth(ProviderId)` path runs (containerized) before a forge
session when `now >= expiry - skew`, exchanging `refresh_token` for a fresh
`access_token` and rewriting the secret. Mirrors `secret-rotation` discipline.

### OOB mechanism (resolves Question 2)

Device-code / OOB authorization-code, **no browser forwarding into the enclave**
(matches the order-112 "device code default" note):

1. Host runs `--<provider>-login`; brings up Vault + proxy (as `--github-login`).
2. An ephemeral `--rm` **forge-image** container (the forge image has the agent
   CLIs; the git image does not — resolves Question 4) drives the agent CLI's own
   OAuth, which prints an **auth URL + user-code** to the attached PTY.
3. The operator opens the URL in their **host** browser, authorizes the
   subscription account, and pastes the resulting device/authorization code back
   through the **existing hidden-paste pipe** (`--github-login` plumbing).
4. The CLI completes the token exchange **inside the container**; the resulting
   `{access,refresh,expiry,scope}` are written to `secret/<provider>/oauth` via
   the in-container `vault-cli.sh`. The host never sees any token.

### Egress (resolves Question 5 — defers exact FQDNs)

Each OAuth flow needs its provider's auth + token endpoints allowlisted BEFORE it
can succeed; exact FQDNs come from the deny-log harvest in
`agent-services-egress-allowlist-research-2026-06-28.md` (order 129), not guessed
here. Known parent domains to confirm there: `claude.ai` /
`console.anthropic.com`; `auth.openai.com` / `chatgpt.com`; `accounts.google.com`
/ `oauth2.googleapis.com`. The impl packet (132) depends on the allowlist impl
(order 130) landing those.

### `run_provider_login` API shape (resolves Question 6 / deliverable)

```rust
enum AuthModel { OAuthDeviceCode }          // ApiKeyPaste added by order 143
struct ProviderLoginSpec {
    provider: ProviderId,
    model: AuthModel,
    login_image: &'static str,              // forge image
    vault_oauth_path: String,               // secret/<provider>/oauth
}
fn run_provider_login(spec: ProviderLoginSpec) -> Result<(), String>;
// mirrors run_github_login: ensure vault+proxy -> ephemeral --rm forge container
// with an AppRole lease -> drive CLI OAuth over PTY -> operator OOB-authorizes on
// host browser -> paste code back -> CLI token exchange in-container -> write
// secret/<provider>/oauth via vault-cli.sh -> verify -> host never holds a token.
```

Tray surface (Question 6): a per-provider authenticated indicator mirroring the
github-login one, plus a re-login/refresh affordance; the tray leaf stays
operator-gated (no autonomous login).

## Goal

Prepare the three interactive login flows the operator named, mirroring the
proven `--github-login` pattern: a containerized, out-of-band login that stores
the credential **in Vault** (never on the host), so forge agents run
credential-free and the host never sees the raw secret.

## What already exists (build on this)

- `--github-login` (`run_github_login` in `main.rs`): brings up Vault + proxy,
  runs an ephemeral `tillandsias-git --rm` container with an AppRole lease, reads
  the token via a robust `read`/`--with-token` pipe, writes it to Vault with the
  in-container `vault-cli.sh`, verifies, and the host never touches the value.
- `ProviderId` enum (order 112): `Anthropic` / `Openai` / `Gemini` with
  `vault_segment()` → `secret/{anthropic,openai,gemini}/api-key`, `env_var()` →
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`, and
  `read/write_provider_api_key`. `build_forge_agent_run_args` already injects
  these env vars into forge containers.

## Questions to Resolve (deliverable)

1. **Auth model per service** (the crux — decide API-key vs OAuth/subscription):
   - **Claude Code**: API key (`secret/anthropic/api-key`, exists) **vs** Claude.ai
     subscription OAuth (browser/device-code). Which does the operator want as the
     default `--claude-login`? OAuth needs a redirect/device-code OOB flow.
   - **Codex**: OpenAI API key (`secret/openai/api-key`) **vs** ChatGPT sign-in
     (OAuth via chatgpt.com). Decide default.
   - **Antigravity**: Google account OAuth (Gemini/Cloud Code) — almost certainly
     OAuth/device-code, not a bare API key. Confirm the credential it persists.
2. **OOB / device-code vs paste:** `--github-login` uses a hidden paste. For
   API-key services, reuse the paste-into-container pattern. For OAuth services,
   define the device-code (URL + code shown in terminal) flow — no browser
   forwarding into the enclave (matches the order-112 "device code default" note).
3. **Vault schema:** API-key flows reuse `secret/<provider>/api-key`. OAuth flows
   need a token + refresh-token schema (`secret/<provider>/oauth` { access,
   refresh, expiry }) and a refresh path. Define it.
4. **Containerized boundary:** which `--rm` image runs each login (the forge image
   has the agent CLIs; the git image does not). Confirm the CLI is present to
   drive its own login inside the container, OR define a minimal login helper.
5. **Egress:** each flow depends on the allowlist research — the login endpoints
   (auth.openai.com, claude.ai, accounts.google.com, …) MUST be allowlisted first.
6. **Tray surface:** how login status is shown per provider (mirrors the
   github-login authenticated indicator) and whether re-login/rotation is offered.

## Deliverable

A verdict table: per service → {auth model chosen, Vault schema, container image,
OOB vs paste, required egress endpoints, refresh policy}, plus the shared
`run_provider_login(ProviderId, AuthModel)` shape the impl packet implements.

## Exit Criteria

- Auth model decided per service (API-key vs OAuth) with operator sign-off noted
- Vault schema for OAuth tokens defined (if any OAuth flow chosen)
- Containerized login boundary + required egress endpoints listed per service
- Shared `run_provider_login` API shape sketched for the impl packet

## Related

- `agent-login-flows-impl-2026-06-28.md`
- `agent-services-egress-allowlist-research-2026-06-28.md` (egress prerequisite)
- `plan/issues/forge-harness-auth-vault-proxy-2026-06-27.md` (order 112 — ProviderId + key injection)
