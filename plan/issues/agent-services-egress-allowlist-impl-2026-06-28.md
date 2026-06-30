# Impl: Agent-Services Egress Allowlist + Antigravity Wiring

**Status:** `pending` (blocked on research deny-log harvest)
**Owner:** linux
**Depends on:** `agent-services-egress-allowlist-research-2026-06-28`
**Date:** 2026-06-28
**Kind:** enhancement
**Trace:** `spec:proxy-container`, `spec:proxy-egress-allowlist`

## Intent

Apply the research's confirmed allowlist delta so claude / codex / antigravity
reach their auth + telemetry + model endpoints, and wire antigravity as a
launchable forge agent.

## Work

1. **Allowlist delta** — add the research-confirmed parent domains to
   `images/proxy/allowlist.txt`, grouped + commented per agent, respecting the
   no-duplicate-subdomain rule. Add `no_bump_domains` / `bump_domains` entries in
   `squid.conf` as the research classifies each (auth/OAuth domains are typically
   no-bump; package/registry-style are bump).
2. **Antigravity agent wiring** — add `images/default/entrypoint-forge-antigravity.sh`
   (mirroring `entrypoint-forge-claude.sh`/`-codex.sh`), and the launch surface:
   a `LaunchKind`/`LeafAction` entry only if the operator approves a new tray
   leaf (the menu is currently 6 leaves — adding a 7th is a UX decision, file as a
   sub-question, do NOT add unilaterally).
3. **Litmus** — `litmus:agent-egress-allowlist-shape` pins that each agent's
   required parent domains are present in `allowlist.txt` (grep), so a future edit
   can't silently drop them.

## Verifiable Closure

- Re-run each agent through the proxy; `podman logs tillandsias-proxy | grep TCP_DENIED`
  shows **zero** denials for the agent's required endpoints.
- A connectivity probe from the forge image returns success (HTTP 200/expected
  auth challenge, not a proxy-resolve error) for each new domain.
- `litmus:agent-egress-allowlist-shape` green.

## Exit Criteria

- allowlist.txt + squid.conf updated with the confirmed delta (no FATAL dupes)
- antigravity launchable as a forge agent (entrypoint present; tray leaf gated on operator approval)
- zero TCP_DENIED for claude/codex/antigravity required endpoints
- litmus pinned + green; `./build.sh --check` passes

## Related

- `agent-services-egress-allowlist-research-2026-06-28.md` (blocker)
- `agent-login-flows-impl-2026-06-28.md` (the login flows that exercise these endpoints)
