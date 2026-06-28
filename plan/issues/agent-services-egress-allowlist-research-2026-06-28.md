# Research: Agent-Services Egress Allowlist (claude / codex / antigravity)

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-28
**Kind:** research
**Trace:** `spec:proxy-container`, `spec:proxy-egress-allowlist`, `spec:enclave-network`

## Problem

Claude, Codex, and Antigravity agents "fail to launch and connect at all". The
enclave proxy (`images/proxy/squid.conf` + `allowlist.txt`) is the only egress
path, so a missing allowlist entry is a hard `TCP_DENIED` and the agent can't
reach its auth/telemetry/model endpoints.

The **model APIs are already allowlisted** (`.anthropic.com`, `.openai.com`,
`.googleapis.com`, `.google.com`), so the failures are almost certainly in the
**auth / sign-in / telemetry** endpoints each CLI hits at startup, NOT the model
API. The operator's directive: **do not guess** — determine the exact endpoints.

Additional finding: there is **no `entrypoint-forge-antigravity.sh`** in
`images/default/` (only claude/codex/opencode). Antigravity is not wired as a
forge agent yet — so it "fails to launch" partly because it does not exist as a
launchable agent. The impl packet must add it.

## Non-Guessing Method (the deliverable's evidence)

Squid logs to `access_log stdio:/dev/stdout` and `cache_log stdio:/dev/stderr`,
so **`podman logs tillandsias-proxy`** contains every `TCP_DENIED` with the exact
FQDN. The external-logs contract also reserves `denied.log` for this. Procedure:

1. Bring the enclave up (`tillandsias --init`); confirm `tillandsias-proxy` healthy.
2. For each agent (claude, codex, antigravity), launch it through the forge and
   drive it to the point of failure (login + first request).
3. Harvest the denied FQDNs:
   ```bash
   podman logs tillandsias-proxy 2>&1 | grep -Eo 'TCP_DENIED[^ ]* [^ ]*' 
   # or, once the producer lands: read .../external-logs/proxy/denied.log
   ```
4. Record the **exact** denied domain set per agent. That set — not documentation
   guesswork — is the allowlist delta.

## Known-likely gaps (to CONFIRM via step 3, not assume)

These are documented endpoints to *look for* in the deny log, not to add blindly:
- **Claude Code**: `statsig.anthropic.com` (covered by `.anthropic.com`?), `statsig.com`
  (NOT covered), `sentry.io` (NOT covered), `claude.ai` OAuth (NOT covered).
- **Codex**: `auth.openai.com` (covered by `.openai.com`), `chatgpt.com` (NOT
  covered — ChatGPT sign-in), `platform.openai.com` (covered).
- **Antigravity** (Google agentic IDE, Codeium/Windsurf lineage): `accounts.google.com`
  (covered by `.google.com`), `cloudcode-pa.googleapis.com` (covered by
  `.googleapis.com`), and possibly `.codeium.com` / Windsurf endpoints (NOT
  covered). Confirm via deny log; antigravity agent wiring is also missing.

## Squid duplicate-subdomain caveat

`allowlist.txt` header: Squid 6.x treats a subdomain of an already-listed domain
as a FATAL error. Any delta MUST avoid listing a subdomain of an existing entry
(e.g. do not add `statsig.anthropic.com` — `.anthropic.com` already covers it).

## Deliverable

A per-agent table of confirmed `TCP_DENIED` FQDNs (from the proxy log), reduced to
the minimal allowlist delta (parent domains, no duplicate subdomains), plus the
no-bump/bump classification for each. Feeds the impl packet.

## Exit Criteria

- Per-agent confirmed denied-domain list captured from `tillandsias-proxy` logs (evidence cited)
- Minimal allowlist delta derived (no duplicate-subdomain FATALs)
- bump vs no-bump decision per new domain
- Antigravity agent-wiring gap documented for the impl packet

## Related

- `agent-services-egress-allowlist-impl-2026-06-28.md`
- `agent-login-flows-research-2026-06-28.md`
- `images/proxy/allowlist.txt`, `images/proxy/squid.conf`, `images/proxy/external-logs.yaml`
