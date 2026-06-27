# Forge Harness Auth via Vault + Proxy Header Injection

**Status:** `pending`
**Owner:** linux
**Date:** 2026-06-27
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
