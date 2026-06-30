# Research: Agent Login Flows (--claude-login / --codex-login / --antigravity-login)

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-28
**Kind:** research
**Trace:** `spec:tillandsias-vault`, `spec:secret-rotation`, `spec:forge-as-only-runtime`

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
