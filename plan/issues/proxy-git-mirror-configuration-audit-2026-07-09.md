# Proxy & Git Mirror Configuration Audit

**Date:** 2026-07-09
**Classification:** audit+bug-fix
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The Squid proxy and git mirror service are critical infrastructure for enclave
isolation and credential-mediated git operations, but their configuration has grown
organically. Specific known and suspected issues:

1. **Proxy allowlist gaps**: The allowlist in `images/proxy/allowlist.txt` and
   `squid.conf` may be missing domains needed by `gh auth login` or git
   operations. The HTTP 401 on `api.github.com` during `--github-login`
   (2026-07-09) may be proxy-related (TLS interception, header injection).

2. **Proxy TLS interception**: The CA bundle is managed by `ensure_ca_bundle` but
   may not be propagated correctly to all containers. The git-login container
   may be missing the CA cert needed to trust the proxy's TLS termination.

3. **Git mirror forwarding**: Order 167 (git-mirror-upstream-forwarding) fixed
   origin remote configuration, but mirror push forwarding still has edge cases:
   stale refs after push, HTTP 403 on lighttpd git-http-backend, credential
   injection for the mirror's upstream push.

4. **No proxy health or config litmus**: There is no automated check that the proxy
   is functioning correctly (allowlist matches expected domains, TLS cert chain is
   valid, sslcrtd is initialized before accepting connections).

5. **Proxy env duplication**: `http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`
   are all set (both lowercase and uppercase). This is correct for compatibility but
   should be documented as intentional.

## Impact

GitHub authentication fails on the primary development host. Git mirror forwarding
may silently strand commits. No automated proxy health verification exists.

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

1. **Proxy Configuration Inventory**: Full audit of `squid.conf`, `allowlist.txt`,
   `ensure_proxy_running`, and all proxy env injection points. Verify allowlist
   covers all required domains for `gh`, `git`, forge agents, and diagnostics.

2. **TLS Certificate Chain Audit**: Trace the CA cert from generation
   (`ensure_ca_bundle`) through podman secrets to container trust stores
   (`/etc/squid/certs/`, container CA bundle, vault TLS). Verify every container
   that needs HTTPS egress has the CA.

3. **Git Mirror Forwarding Verification**: End-to-end test of forge -> mirror ->
   GitHub push path. Verify refs are consistent after push. Add litmus.

4. **Proxy Health Litmus**: Add `litmus:proxy-end-to-end-health` that verifies
   DNS resolution through proxy, HTTPS CONNECT tunnel, allowlist enforcement,
   and TLS interception all work.

5. **Spec/Cheatsheet Patch List**: Files in `openspec/specs/` and `docs/cheatsheets/`
   that need updating.
