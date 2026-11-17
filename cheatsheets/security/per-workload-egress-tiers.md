---
tags: [egress-policy, squid, ssl-bump, sni, podman-network, network-policy, fqdn-policy]
languages: [ini]
since: 2026-11-07
last_verified: 2026-11-07
sources:
  - https://wiki.squid-cache.org/Features/SslPeekAndSplice
  - https://www.squid-cache.org/Doc/config/host_verify_strict/
  - https://www.squid-cache.org/Doc/config/acl/
  - https://www.squid-cache.org/Doc/config/external_acl_type/
  - https://www.squid-cache.org/Doc/config/delay_pools/
  - https://www.squid-cache.org/Doc/config/logformat/
  - https://docs.podman.io/en/latest/markdown/podman-network-create.1.html
  - https://docs.podman.io/en/latest/markdown/podman-network-connect.1.html
  - https://kubernetes.io/docs/concepts/services-networking/network-policies/
  - https://docs.cilium.io/en/stable/security/dns/
  - https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
  - https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_proxy
  - https://verdaccio.org/docs/uplinks
  - https://docs.gomods.io/
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
pull_recipe: see-section-pull-on-demand
---

# Per-workload egress tiers: fail-closed outbound policy for each container

**Use when:** giving different containers different outbound access (none,
siblings only, host, curated internet), keeping TLS end to end, and keeping
the policy from turning into one hand-kept list.

## Mechanisms

- **Podman topology is the policy.** `--internal` disables forwarding on the
  bridge, sets no default route, and aardvark-dns answers only container names
  (verified). `isolate=strict` (the default) blocks traffic between bridge
  networks. A container can join several networks. Podman has no NetworkPolicy
  equivalent.
- **Squid, decided on SNI, spliced not bumped.** SslBump step 2 reads the
  Client Hello SNI; `splice` keeps the client↔origin TLS intact (verified).
  Match with `ssl::server_name`, not `dstdomain`: before bumping, `dstdomain`
  sees only the CONNECT target, which may be an IP (verified).
  - **Per-tier rules:** one `http_port` per tier and `myportname`, or `src`
    subnets per network. `external_acl_type` helpers can tag a request with
    `note`.
  - **Per-client limits and audit:** `delay_pools` class 2/3 give per-client
    buckets, and `logformat` can record `%ssl::>sni` and `%>a`.
- **SNI can be forged** (verified). Splicing on SNI alone is not proof of the
  destination: the proxy must connect to what the SNI resolves to, not to a
  client-chosen IP. `host_verify_strict` covers the Host header, not SNI, and
  is gone in Squid v8 (verified).
- **Kubernetes-class equivalents:**
  - **Kubernetes NetworkPolicy:** selects by label and is default-deny once it
    applies; it has no FQDN matching.
  - **Cilium `toFQDNs`:** enforced by a DNS proxy; `*.x` does not match `x`
    (verified).
  - **Istio:** `REGISTRY_ONLY` plus an egress gateway allows by SNI and
    workload identity.
  - **Envoy:** a dynamic forward proxy with SNI passthrough.

  All of these are identity-based rather than IP-based.

## Scaling past a hand-kept list

- **Mirrors instead of egress:** one allowed upstream per ecosystem (Verdaccio
  for npm, Athens/GOPROXY for Go, devpi for PyPI). Workloads then talk only to
  a sibling mirror.
- **Category lists** (UT1, squidGuard) via helpers. These are coarse.
- **Approve on first request:** deny, queue the name, and let a person approve
  it, with Little Snitch/LuLu-style decisions held server-side in an
  `external_acl_type` helper and its cache TTLs.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: several upstream doc sites; the summary above carries the claims used here.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.

### Source

- **Upstream URL(s):**
  - `https://wiki.squid-cache.org/Features/SslPeekAndSplice`
  - `https://docs.podman.io/en/latest/markdown/podman-network-create.1.html`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/egress-tier-docs/`
- **License:** vendor documentation licences (see each site)
- **License URL:** see each upstream URL

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/egress-tier-docs"
mkdir -p "$TARGET_DIR"
curl --fail --silent --show-error -L "https://wiki.squid-cache.org/Features/SslPeekAndSplice" -o "$TARGET_DIR/0.html"
curl --fail --silent --show-error -L "https://docs.podman.io/en/latest/markdown/podman-network-create.1.html" -o "$TARGET_DIR/1.html"
```

### Generation guidelines (after pull)

1. Read the pulled files for the exact option names and defaults cited above.
2. If your project needs a project-specific version, generate it at `<project>/.tillandsias/cheatsheets/security/per-workload-egress-tiers.md` using `cheatsheets/TEMPLATE.md`.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.

## Provenance

Retrieved 2026-11-07 by a research agent at the operator's request. Items
marked verified were read on the cited page that day. Everything else came from
the agent's own knowledge, with the cited page as the place to confirm it. That
includes the Squid ACL/delay_pools specifics, Calico/Istio/Envoy and the
mirrors. The SNI-to-destination check is inferred and must be tested.
