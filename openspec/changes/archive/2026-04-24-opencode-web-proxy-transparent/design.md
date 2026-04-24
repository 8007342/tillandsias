# Design: opencode-web-proxy-transparent

## Context

OpenCode Web, running as `opencode serve` inside the forge container, is a Bun
binary. Every outbound HTTP(S) call it makes — provider APIs, registry fetches,
local ollama probes — is governed by the Bun runtime, which fully honours
`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, and `NODE_EXTRA_CA_CERTS`. Our enclave
routes all traffic through a Squid proxy with a domain allowlist (strict on port
3128, permissive on 3129 used only during image builds).

Observed failure modes from proxy logs (2026-04-24):

```
1777019140.710   0 10.89.0.3 TCP_DENIED/403 300 HEAD http://0.0.0.0:11434/
1777019141.790   0 10.89.0.5 TCP_DENIED/403 3855 GET http://inference:11434/api/version
1777019142.488   7 10.89.0.5 TCP_DENIED/200 0 CONNECT models.dev:443
```

Root cause: (a) intra-enclave hostnames are proxied because `NO_PROXY` does not
exclude them; (b) OpenCode's registry host `models.dev` is absent from the
allowlist. Bun honours the env correctly; the env and the allowlist are wrong.

## Decisions

### Decision 1 — NO_PROXY covers the enclave, not just loopback

Current forge NO_PROXY: `localhost,127.0.0.1,git-service`.

New forge NO_PROXY: `localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy`.

Adds:
- `0.0.0.0` and `::1` — ollama and other tools often bind and probe these
  interfaces directly (see the `HEAD http://0.0.0.0:11434/` denial above).
- `inference` — the ollama container's enclave-internal hostname. OpenCode reaches
  it via `OLLAMA_HOST=http://inference:11434`; that call must never traverse the
  proxy.
- `proxy` — belt-and-braces so any tool that opens a request to the proxy's own
  hostname (via misconfig) does not bounce through Squid.

Inference NO_PROXY is set to the same value, ensuring ollama's internal probes
stay local. Previously it was unset, causing the `HEAD http://0.0.0.0:11434/`
denials.

### Decision 2 — Allowlist is the only egress gate

The SSL bump in `squid.conf` is currently `splice all` — peek-at-SNI for
allowlist filtering, then passthrough. We do NOT enable selective bumping in this
change, because:

- Every allowed destination still has its TLS terminated at the client (Bun) with
  the original origin certificate. No certificate pinning risk.
- The CA-trust path (NODE_EXTRA_CA_CERTS + SSL_CERT_FILE combined bundle) is only
  exercised when we actually bump. Leaving `splice all` avoids the TODO-risk
  called out in `squid.conf:78-86` ("non-root CA trust in system store").
- Caching benefit from bumping HTTPS responses is secondary to correctness.
  Re-enabling bump is a later change once we have at least one failure signal
  that passthrough is insufficient.

So "transparent" in this proposal means: from OpenCode's perspective, the proxy
imposes no extra round trip, no cert errors, no surprise 403s for intended
egress destinations. It does not mean "MITM everything."

### Decision 3 — Allowlist expansions are minimal and documented

Three explicit additions, each justified:

- `.models.dev` — canonical OpenCode registry; without it OpenCode cannot
  discover or validate models. This is the observed denial.
- `.openrouter.ai` — OpenRouter is one of OpenCode's default provider routes.
  Users who pick "OpenRouter" in the agent config get blocked today.
- `.helicone.ai` — Helicone is the default telemetry / gateway target for a
  subset of OpenCode flows.

We do NOT add bare `models.dev` or `openrouter.ai` because Squid's
`dstdomain .models.dev` matches both the bare domain and all subdomains. Adding
the bare form would be a duplicate and Squid 6.x treats duplicate dstdomain
entries as a fatal startup error (see the warning at the top of
`images/proxy/allowlist.txt`).

### Decision 4 — Profile is source of truth; entrypoint scripts remain as-is

The forge and inference containers both read env vars injected by the host at
`podman run` time. `container_profile.rs` is the single source of env-var truth.
The entrypoint scripts (`entrypoint-forge-opencode-web.sh`, etc.) do not need
changes for this fix — they already trust the CA chain and hand off to
`opencode serve`. The CA-trust comment in the entrypoint is kept as documentation
for future readers.

### Decision 5 — No NODE_TLS_REJECT_UNAUTHORIZED=0 anywhere

Tempting as a one-line fallback, but it opens a hole big enough to drive every
agent-in-a-sandbox threat model through. The CA-chain path is complete and
validated; disabling verification is a regression, not a fix.

## Alternatives Considered

- **Disable the proxy allowlist in the forge profile.** Rejected: the allowlist
  is the primary defence against credential-smuggling agents. Dropping it makes
  every forge container a cert-trusted tunnel to anywhere.
- **Proxy-bypass everything (NO_PROXY="*") in the forge.** Rejected for the same
  reason. Intra-enclave traffic must bypass, external traffic must go through.
- **Enable selective SSL bump for cache benefit.** Deferred — out of scope, and
  adds CA complexity that the current allowlist+splice path does not need.
- **Hard-code OpenCode's provider list into the allowlist.** Rejected — most
  providers are already listed. We add only what the observed traffic + one
  tier of commonly-used providers (OpenRouter, Helicone) need. Future additions
  go through the same delta-spec flow.

## Trace requirements

- `@trace spec:opencode-web-session, spec:proxy-container` on the
  `container_profile.rs` forge NO_PROXY change.
- `@trace spec:inference-container, spec:proxy-container` on the
  `container_profile.rs` inference NO_PROXY addition.
- `@trace spec:proxy-container` on the allowlist additions (inline comments).
- `@trace spec:opencode-web-session` on the new cheatsheet header.

## Verification plan

1. After applying the patch, rebuild the proxy image
   (`scripts/build-image.sh proxy`). No forge image rebuild required.
2. Restart the enclave (via tray Quit + re-launch — which now works after
   `fix-tray-exit-webview-lifecycle`).
3. Trigger Attach Here on a project in web mode, send 3 prompts, and confirm:
   - No `TCP_DENIED/403` entries in the proxy log for `inference:11434`,
     `0.0.0.0:11434`, or `models.dev:443`.
   - OpenCode responds within its normal latency envelope (<5s for model
     selection, streaming thereafter).
4. Confirm ollama's internal health probe no longer hairpins through the proxy
   by checking the proxy log for the absence of `0.0.0.0:11434` entries during
   a 60-second idle window.
