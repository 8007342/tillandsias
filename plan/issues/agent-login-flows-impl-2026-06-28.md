# Impl: Agent Login Flows (--claude-login / --codex-login / --antigravity-login)

**Status:** `pending` (blocked on login-flows research + allowlist)
**Owner:** linux
**Depends on:** `agent-login-flows-research-2026-06-28`, `agent-services-egress-allowlist-impl-2026-06-28`
**Date:** 2026-06-28
**Kind:** enhancement
**Trace:** `spec:tillandsias-vault`, `spec:secret-rotation`

## Intent

Implement the three login flows per the research verdict, as a single
parameterized `run_provider_login(ProviderId, AuthModel)` mirroring
`run_github_login`, exposed as `--claude-login`, `--codex-login`,
`--antigravity-login` CLI flags (and, where the operator approves, tray menu
entries).

## Sliced Packets (refine after research)

### Slice 1 — Shared `run_provider_login` skeleton + API-key flows (`ready` after research)
- Factor the `run_github_login` shape into a provider-neutral
  `run_provider_login(provider, auth_model, debug)`: ensure Vault + proxy
  (`ensure_proxy_running`), mint an AppRole lease, run the `--rm` container, do
  the OOB/paste credential capture, write to Vault via in-container `vault-cli.sh`,
  verify, host never sees the value.
- Wire `--claude-login` / `--codex-login` for the **API-key** model first
  (reuses `secret/<provider>/api-key` + the existing `read/write_provider_api_key`).
- Verifiable: `--claude-login` stores a key at `secret/anthropic/api-key` and a
  forge claude session starts with `ANTHROPIC_API_KEY` injected (no host env).

### Slice 2 — OAuth/device-code flow (if research selects it for any service)
- Implement the device-code OOB flow (URL + code in terminal, poll for token),
  the `secret/<provider>/oauth` schema, and the refresh path.
- `--antigravity-login` (Google OAuth) + any OAuth-default service.

### Slice 3 — Tray surface + status (operator-gated)
- Per-provider login status indicator; re-login/rotation entry. Adding tray menu
  leaves is operator-gated (the menu is 6 leaves today).

## Verifiable Closure

- Each `--<provider>-login` completes end-to-end against a real account and the
  credential lands in Vault (verified by an in-container read), host never sees it.
- A forge session for that provider launches and reaches its API through the proxy
  (zero TCP_DENIED — depends on the allowlist impl).
- Unit tests for `run_provider_login` arg construction + the Vault schema.

## Exit Criteria

- `--claude-login`, `--codex-login`, `--antigravity-login` implemented via shared `run_provider_login`
- Credentials stored in Vault per the research schema; host never holds raw values
- Each provider's forge session authenticates through the proxy
- `./build.sh --check` and `--test` pass

## Related

- `agent-login-flows-research-2026-06-28.md` (blocker)
- `agent-services-egress-allowlist-impl-2026-06-28.md` (egress prerequisite)
- order 112 `forge-harness-auth-vault-proxy` (ProviderId + key injection foundation)
