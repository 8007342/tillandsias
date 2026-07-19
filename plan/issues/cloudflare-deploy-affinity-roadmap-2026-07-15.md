# Cloudflare deploy + service/environment affinity — roadmap (order 362)

- Date: 2026-07-15 (security-boundary + rung-tree + sign-off sections added
  2026-07-16 by linux-tlatoani-claude-20260716T0725Z)
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

## Security boundary

The public-exposure feature must not weaken the enclave's core invariant:
**forge containers hold ZERO long-lived credentials.** The Cloudflare work
reuses the existing provider-login security model verbatim:

- **Credential at rest**: the Cloudflare token lands in the vault under
  `secret/cloudflare/...`, exactly as `secret/github/token` does today. It is
  written once by the ephemeral `--cloudflare-login` container and never
  echoed to argv, env, or any forge log.
- **Forge-zero-credential invariant**: the forge's OWN vault policy CANNOT
  read the raw Cloudflare token (same as it cannot read `secret/github/token`,
  main.rs ~8622). Any component that needs Cloudflare access restores it via a
  **scoped AppRole** (`VAULT_ROLE`-style, the `git-mirror`/`provider-oauth-vault
  restore` pattern) that mints a short-lived, purpose-scoped token at use time.
- **Login isolation**: `--cloudflare-login` runs in an ephemeral, capability-
  probed container with the standard security flags (`--cap-drop=ALL`,
  `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`); a
  `--with-token` automation path mirrors `--github-login --with-token`.
- **Tunnel / egress boundary**: the tunnel credential is scoped to a single
  tunnel/domain, not account-wide, and rotates on a short cadence. DNS updates
  go through the Cloudflare API using that scoped token with a short record TTL
  (~45 min refresh). Egress rides the per-tillandsias WARP client — the enclave
  egress-proxy boundary is unchanged; no new inbound host ports (the tunnel is
  outbound-initiated, like the rest of the enclave).
- **Ephemeral by default**: public serve is per-prompt opt-in. An ephemeral
  serve tears down BOTH the container AND its DNS record + tunnel on stop — it
  "dies with the stack," the same lifecycle as enclave `--rm` reaping
  (cf. order 373 tunnel criterion "tunnel dies with the stack"). `localhost` /
  `test.*` never leave the host.
- **Blast radius**: a leaked tunnel token exposes only its one tunnel/domain,
  never the vault or other secrets; the rotation cadence bounds the exposure
  window. The login token in vault is the single high-value secret and lives
  behind the same policy wall as every other provider credential.

## Rung tree (shaped ledger packets)

The doc rungs are already shaped as ledger children of
`web-share-release-milestone` (order 373):

1. **`--cloudflare-login` → vault** — smallest rung, mirrors provider logins.
   → ledger packet **order 377 `cloudflare-login-implementation`** (ready,
   gated on this sign-off).
2. **Ephemeral public serve of ONE local web container** via a Cloudflare
   tunnel for a user-owned domain (DNS create + short TTL + ~45 min refresh).
   → ledger packet **order 378 `warp-tunnel-ephemeral-public-serve`**.
3. **One-prompt public share flow** (the operator's "host in www.<domain>.com"
   prompt end to end). → ledger packet **order 379
   `one-prompt-public-share-flow`**.
4. **Domain → tillandsia affinity model** (research) and the **production tier**
   (mesh / storage / LB) — far horizon; to be shaped as their own rungs after
   rungs 1–3 land.

## Design decisions — resolved at sign-off (The Tlatoāni, 2026-07-16)

- **D1 — WARP / tunnel / TLS placement → RESEARCH (order 388)**. Not a blind
  decision: The Tlatoāni's steer is to co-locate the Cloudflare tunnel + WARP
  client + **transparent HTTPS/TLS termination in the proxy/router container**.
  Rationale: published web containers live in the enclave and are routed to
  from the reverse proxy; if that proxy holds the outbound tunnel it also
  handles incoming traffic; terminating TLS in ONE place lets web containers
  stay cert-free, and free/self-signed cert issuance (ACME/Let's Encrypt) lives
  next to the proxy. It must host+route MULTIPLE https hosts. Filed as research
  **order 388** to validate this placement (vs alternatives), the multi-host
  HTTPS routing, and the cert strategy — rather than committing blind.
- **D2 — Tunnel credential scope + rotation** → folded into the order-388
  research and rung-2 shaping (order 378): per-tunnel scoped token; short TTL
  (~1h) with refresh while the container is live.
- **D3 — Environment selection → SCOPED NOW + RESEARCH (orders 389, 390)**.
  For now: ONLY **ephemeral `dev`/`test`.<domain-we-own>**, fully mapped through
  a tunnel to a domain we own, ~1h TTL with refreshes while the container is
  live. The broader progression (daily → staging → prod → canary) follows an
  **evidence-gating ladder** — assume the user doesn't know what they're doing,
  so each stage is unlocked by evidence of the prior (as remote projects gate on
  github login and agents gate on their logins today; publish-to-prod would gate
  on staging evidence, staging on daily builds, daily on stable local dev).
  Filed as long-running research **order 389**. A **GitHub App** for
  fine-grained user↔GitHub interactions (hooks/actions/workflows) and
  temporarily-issued elevated tokens for promotions/releases is filed as
  research **order 390** (relates to the existing installation-token evaluation
  in order 319 / the git-mirror credential work, but broader in scope).
- **D4 — Rung 1 scope → APPROVED as-is**. Order 377 = `--cloudflare-login` →
  vault + login-preflight seam + flag & litmus; implementation only, no serving.

## Sign-off record

- **Signed off by**: The Tlatoāni, 2026-07-16 (interactive session).
- **Scope approved**: unblock rung 1 (order 377 `--cloudflare-login` → vault).
  Serving/tunnel rungs (378/379) proceed only for ephemeral `dev`/`test`.<domain>
  for now; production tiers await the order-389 evidence-gating research.
- **Recorded by**: linux-tlatoani-claude-20260716T0725Z (order 362 closed;
  research spun out to orders 388/389/390).
