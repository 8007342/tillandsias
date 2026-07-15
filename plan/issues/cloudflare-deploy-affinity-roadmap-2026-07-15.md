# Cloudflare deploy + service/environment affinity — roadmap (order 362)

- Date: 2026-07-15
- Class: research (multi_cycle roadmap; the milestone AFTER the local-host
  enclave service catalog)
- Directive: The Tlatoāni, 2026-07-15

## Vision (operator, verbatim intent)

After serving the local host, add `--cloudflare-login` (same shape as the
provider logins: a device/API login whose credential lands in the vault).
Then, after a successful login, a forge agent prompt like:

- **"host in www.<domain-i-own>.com"** → serve the local web container
  publicly via a **Cloudflare tunnel** with **DNS updates every ~45 min at a
  short TTL**; each tillandsias runs its own **Cloudflare WARP client**.
- **"publish this local work to dev.<domain-i-own>.com"** → an *ephemeral*
  public serve (up only while running).
- **"deploy to test.<project>.localhost"** → stays purely ephemeral/local.

Long term: **multiple tillandsias with service + environment AFFINITY** — a
"deploy to www.<domain-they-own>.com" routes to the RIGHT tillandsia
(production: distributed mesh, distributed storage, load balancing), while
localhost/test stays ephemeral. Goal: any cheap laptop + a cheap Cloudflare
domain can self-host — ephemeral (on at times) or production-grade.
"We'll take care of all the complexity."

## Relationship to the current milestone

This is explicitly the NEXT milestone. The enclave-service-catalog
milestone (order 353) serves `https://www.<project>.localhost` on the Linux
host only. This roadmap extends the SAME publish-locally invocation from
loopback to public via Cloudflare. Do not pull this into the local-host
milestone.

## Reuse / consistency anchors

- `--cloudflare-login` mirrors `--codex-login`/`--claude-login`/`--agy-login`
  exactly: capability-probed device/API login in an ephemeral container,
  opaque credential stored in the vault under `secret/cloudflare/...`, a
  scoped forge policy for restore. The provider-login machinery
  (`run_provider_login`, `ProviderDeviceAuthSpec`, `provider-oauth-vault`)
  is the template.
- The "which environment / which tillandsia" routing is an affinity/service
  -registry problem — relate to the multi-tillandsias coordination the
  distributed-work methodology already models for dev hosts.

## First rungs (to be shaped; Tlatoāni signs the design first)

1. `--cloudflare-login` → credential into vault (smallest, mirrors provider logins).
2. Ephemeral public serve of ONE local WEB container via a Cloudflare tunnel
   for a domain the user owns (DNS create + short TTL + ~45 min refresh).
3. Domain → tillandsia affinity model (research).
4. Production tier (mesh / storage / LB) — far horizon.

## Open questions for The Tlatoāni (later)

- WARP client per tillandsias: bundled container vs host daemon?
- Tunnel credential scope + rotation cadence vs the 45-min DNS refresh.
- Ephemeral vs production selection: prompt-driven, or per-domain config?
