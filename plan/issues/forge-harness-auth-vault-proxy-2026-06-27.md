# Forge Harness Auth via Vault + Proxy Header Injection

**Status:** `resolved`
**Owner:** linux
**Date:** 2026-06-27
**Research completed:** 2026-06-27T04:30Z
**Trace:** `spec:tillandsias-vault`, `spec:proxy-container`, `spec:forge-as-only-runtime`

## Problem Statement

Claude Code, Codex, and other forge harnesses currently run "credential-free"
inside the forge. The comment in `entrypoint-forge-claude.sh` says:
> "Claude starts credential-free. Authentication may happen interactively for
> this ephemeral session, but host credentials and API keys never enter forge."

This means agents cannot call LLM APIs at all unless the user re-authenticates
interactively on every container launch.

## Target Architecture

```
[operator] --github-login-style isolated --rm auth container
      ↓ device code flow (URL + code shown to operator)
      ↓ token captured → Vault at secret/<provider>/token
      ↓
[forge] sends request to api.anthropic.com
      ↓
[squid proxy] intercepts HTTPS (SSL bump), reads token from Vault via helper
      ↓ injects Authorization header (or x-api-key)
      ↓
[api.anthropic.com] receives authenticated request
```

## Provider Research Questions

### Claude Code (Anthropic)
- `claude auth login` → OAuth. Does it support `--device-code` / device flow?
- Alternative: `ANTHROPIC_API_KEY` env var. Where would we store this?
- Does `claude` re-read `ANTHROPIC_API_KEY` on each request or cache at startup?
- Session format: `~/.claude/.credentials.json` (OAuth) vs env var (API key)
- Which flow does the Anthropic device auth endpoint use?

### Codex (OpenAI)
- `codex auth` flow? Supports device code (`/oauth/device/code`)?
- Alternative: `OPENAI_API_KEY` env var — stable across container restarts?
- API key or OAuth token: which survives a container rebuild?

### Antigravity / Gemini (Google)
- Auth mechanism: `gcloud auth application-default login` or `GEMINI_API_KEY`?
- Device code support via Google OAuth 2.0 device flow?

## Implementation Plan

### Phase 1: Auth container (device code flow)

For each provider, add a `tillandsias --<provider>-login` sub-command that:
1. Launches an isolated `--rm` container (forge image + provider CLI)
2. Runs the device code flow, prints code + URL to operator's terminal
3. Waits for operator to authenticate via browser on another device
4. Captures the resulting token/session
5. Writes it to Vault: `secret/anthropic/token`, `secret/openai/token`, etc.

**Key requirement**: All auth flows must default to "Authenticate in another
device" (device code / out-of-band) — no browser forwarding, no dbus event
listeners, no forwarded display sockets. The code appears in the terminal; the
operator visits the URL on their phone or another browser.

### Phase 2: Proxy header injection

Squid's `url_rewrite_program` or an `external_acl_type` helper can call a
vault-cli subprocess to fetch the token and inject it as an HTTP header.

```squid
url_rewrite_program /usr/local/bin/squid-auth-inject.sh
url_rewrite_children 2 startup=1 idle=1
```

Or simpler with `request_header_replace`:
```squid
acl to_anthropic dstdomain .anthropic.com
request_header_add x-api-key "Bearer $(vault-cli read ...)" to_anthropic
```

The correct approach depends on whether Squid can call an external program
for dynamic header values (it cannot with a static `request_header_add`).
The recommended Squid 6.x approach is an eCAP adapter or a redirect helper.

### Phase 3: Token rotation

Store the long-lived token in Vault. Issue short-lived (1-hour TTL) derived
tokens for each request or each container launch:
- Vault dynamic secrets or a custom periodic rotation job
- The proxy helper always reads a fresh token from Vault on each request
- Token revocation: if a container is compromised, revoke its token in Vault

## Files to Create/Modify

- `crates/tillandsias-headless/src/main.rs` — `--anthropic-login`, `--openai-login` subcommands
- `images/proxy/squid.conf` — auth injection helper
- `images/proxy/Containerfile` — vault-cli installed in proxy image
- `images/proxy/auth-inject.sh` — helper script calling vault-cli
- `openspec/specs/forge-harness-auth/` — new spec

## Dependency

- Vault must be running and GitHub login must be done first (existing)
- `vault-cli` must be available in the proxy container (check Containerfile)

## Exit Criteria

- `tillandsias --anthropic-login` shows a URL + code, operator authenticates
  via browser on another device, token is stored in Vault
- A forge container running `claude` can call `api.anthropic.com` without any
  `ANTHROPIC_API_KEY` env var — the proxy injects the header transparently
- Same for `codex` → `api.openai.com` and any Gemini harness
- `tillandsias --anthropic-login` is idempotent: re-runs silently succeed
  if a valid token is already in Vault

## Research Verdict (2026-06-27T04:30Z)

### Provider Auth Mechanisms

#### Claude Code (Anthropic)

`claude auth login` opens an OAuth browser flow (no `--device-code` flag available).
The token is stored in `~/.claude/.credentials.json` as `claudeAiOauth.accessToken`
(Bearer `sk-ant-oat01-...`) with a ~1hr expiry.

**Forge-friendly path**: `ANTHROPIC_API_KEY` environment variable. Claude Code
reads this before attempting any credential-file lookup. API keys are issued at
[console.anthropic.com](https://console.anthropic.com) with no expiry and are
stable across container restarts.

**Device-code adjacent flow**: `claude auth login` can be run inside an isolated
`--rm` container with `BROWSER=cat` or similar to capture the auth URL rather than
opening it; the operator then visits the URL on another device. This is fragile.
The API key approach is strictly simpler and recommended.

**Vault path**: `secret/anthropic/api-key` → field `key`

#### Codex (OpenAI)

`codex login --with-api-key` reads an API key from stdin:
```
echo "$OPENAI_API_KEY" | codex login --with-api-key
```
This is the canonical non-browser path. OpenAI also supports a true OAuth device
code flow at `https://auth.openai.com/oauth/device/code` for its ChatGPT auth mode,
but the API key path is simpler and device-code-free.

Confirmed: `~/.codex/auth.json` has `{ "auth_mode": "chatgpt", "OPENAI_API_KEY": "...", "tokens": "..." }`.
The `OPENAI_API_KEY` field is written by `--with-api-key` and is what codex uses
for requests; the `tokens` field is the ChatGPT OAuth token (browser-based).

**Forge-friendly path**: `OPENAI_API_KEY` env var injected at container launch.
Alternatively, run `echo "$key" | codex login --with-api-key` inside the forge
container at startup — this writes `~/.codex/auth.json` with the API key and the
container can run non-interactively thereafter.

**Vault path**: `secret/openai/api-key` → field `key`

#### Antigravity / Gemini (Google)

Not installed on this host. Google supports OAuth 2.0 device flow natively via
`https://oauth2.googleapis.com/device/authorize`. For Gemini API:
- `GEMINI_API_KEY` (Google AI Studio API key, `AIza...`) — simplest
- `GOOGLE_APPLICATION_CREDENTIALS` (service account JSON) — enterprise
- `gcloud auth application-default login` — triggers browser OAuth

**Forge-friendly path**: `GEMINI_API_KEY` env var from Vault.

**Vault path**: `secret/gemini/api-key` → field `key`

### Proxy Header Injection (Squid)

Investigated two Squid injection mechanisms:

1. **`url_rewrite_program`**: Can modify destination URLs but cannot add HTTP
   request headers. Insufficient for `x-api-key` / `Authorization` injection.

2. **`request_header_replace` / `request_header_add`**: Static values only;
   cannot call an external program for dynamic per-request header values.

3. **ICAP (`icap_service`)**: Squid 6.x fully supports ICAP (`icap_service` +
   `adaptation_access`). An ICAP `REQMOD` server receives the full HTTP request,
   can add/modify headers, and returns the modified request to Squid.
   This is the correct architecture for dynamic header injection.
   Requires a small ICAP server (e.g. `c-icap`, or a custom Rust `tokio` server
   implementing RFC 3507) running alongside Squid in the proxy container.
   **Deferred to a later implementation slice** — it's the right architecture
   but adds a new process to the proxy container.

### Recommended Architecture (Two-Phase)

**Phase 1 (this slice — implemented)**: Vault storage + env var injection

1. Operator runs `tillandsias --anthropic-login` / `--openai-login`: prompts for
   API key, stores in Vault.
2. At forge container launch, the tray reads the key from Vault and passes it as
   `--env ANTHROPIC_API_KEY=<key>` (or `OPENAI_API_KEY`).
3. The forge container runs with the API key in its environment but NOT hardcoded
   in any image or config file. The key only exists for the lifetime of the
   container launch.
4. Idempotent: re-running `--anthropic-login` with the same key is a no-op.

**Phase 2 (deferred)**: ICAP-based transparent proxy header injection

- Implement a small ICAP `REQMOD` service in the proxy container (Rust or c-icap)
- ICAP server reads provider API keys from Vault on each request
- Forge containers become truly credential-free: no env vars, no keys, no login flow
- Squid forwards `api.anthropic.com` / `api.openai.com` traffic through the ICAP adapter
- Rotation: ICAP server always reads from Vault; rotating the key in Vault takes
  effect immediately for all subsequent requests

### Vault Secret Schema

```
secret/anthropic/api-key  { "key": "sk-ant-api03-..." }
secret/openai/api-key     { "key": "sk-proj-..." }
secret/gemini/api-key     { "key": "AIza..." }
```

Access control:
- `tray-policy`: full CRUD (operator reads/writes at `--xxx-login` time) — already covered by existing `secret/*`
- `proxy-policy` (new, phase 2): read-only on `secret/data/*/api-key` paths
- Forge containers: do NOT read keys directly from Vault (keys are injected by tray as env vars)

### Implementation Done in This Slice

1. Vault helper functions in `vault_bootstrap.rs`:
   - `write_provider_api_key(provider, key)` → writes to `secret/<provider>/api-key`
   - `read_provider_api_key(provider)` → reads back for inject
2. `ProviderId` enum: `Anthropic`, `Openai`, `Gemini`
3. Tray `is_<provider>_logged_in()` probe functions
4. Forge container builder: reads provider key from Vault and adds `--env` at launch

### Files Changed (this slice)

- `crates/tillandsias-headless/src/vault_bootstrap.rs` — provider key helpers
- `crates/tillandsias-headless/src/main.rs` — forge container builder injects provider keys
- `crates/tillandsias-headless/src/tray/mod.rs` — TODO stubs for login menu items (Phase 2: --anthropic-login subcommand)

### Deferred (Phase 2 — separate packet)

- `images/proxy/` — ICAP server implementation in proxy container
- `crates/tillandsias-headless/src/main.rs` — `--anthropic-login`, `--openai-login` CLI subcommands
- `openspec/specs/forge-harness-auth/spec.md` — new spec
