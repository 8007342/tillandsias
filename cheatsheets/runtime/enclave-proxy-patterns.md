---
tags: [enclave, network, proxy, architecture, unix]
languages: []
since: 2026-06-26
last_verified: 2026-06-26
sources: [internal, squid-docs, podman-docs]
authority: internal
status: draft
tier: bundled
---
# Enclave Proxy Patterns

@trace spec:proxy-container, spec:enclave-network

**Use when**: Adding a new container to the enclave, reasoning about whether to
set `HTTP_PROXY` env vars explicitly, or designing how egress traffic is
controlled.

## Provenance

- https://wiki.squid-cache.org/Features/Tproxy4 — iptables TPROXY intercept mode
- https://wiki.squid-cache.org/Features/SslBump — SSL bump with intercept port
- https://github.com/containers/common/blob/main/docs/containers.conf.5.md — containers.conf `[engine] env`
- https://www.kernel.org/doc/html/latest/networking/tproxy.html — kernel TPROXY docs
- **Last updated:** 2026-06-26

## Quick reference: three proxy approaches

| Approach | How it works | Client config needed? | SSL bump? | Notes |
|---|---|---|---|---|
| **Explicit forward proxy** (current) | Client sets `HTTP_PROXY=http://proxy:3128` | Per-container env var | Yes | POSIX standard; fragile at scale |
| **containers.conf injection** | Podman injects proxy env vars for every container | One-time containers.conf entry | Yes | Single injection point; best for rootless Podman |
| **iptables TPROXY intercept** | Kernel redirects port 80/443 to Squid before the packet leaves the NIC | None — fully transparent | Yes (harder) | Requires CAP_NET_ADMIN + kernel modules; truly transparent |

## Current architecture (explicit forward proxy)

Squid listens on port 3128 (strict) and 3129 (build) in **forward proxy** mode.
Containers must have `HTTP_PROXY` / `HTTPS_PROXY` set to `http://proxy:3128`
to route through it. Without those env vars, outbound HTTP/HTTPS traffic either
goes directly to the internet (bypassing the allowlist) or is blocked at the
network level.

`build_stack_common_args` in `crates/tillandsias-headless/src/main.rs` is the
single authoritative injection point. Every container that calls this helper
gets proxy env vars automatically. **Do not add proxy env vars in individual
container builders** — that creates drift.

## Why "transparent" matters

The word in *Transparent Proxy* is load-bearing. A truly transparent proxy
requires **zero per-service configuration** — no env var, no config file, no
knowledge that a proxy exists. Any architecture where adding a new service
requires a new line of proxy config in the launcher code fails this property.

### The Unix principle at stake

POSIX `HTTP_PROXY` / `HTTPS_PROXY` env vars are **application-level**
configuration. They work because `curl`, `git`, `cargo`, `pip` etc. all read
them. But:

- Not every binary respects them (some use `libcurl` incorrectly, some hardcode
  `getaddrinfo`, some use raw sockets).
- The `NO_PROXY` list must be maintained independently for every new container
  and kept in sync when internal hostnames change.
- It is an O(N) maintenance burden: every new container is a chance to forget.
- The env vars leak the internal network topology to every container
  (`NO_PROXY=localhost,127.0.0.1,git-service,tillandsias-git,vault,inference`
  is an inventory of our internal services).

### When env vars ARE the correct approach

Env vars are justified when:
1. The container runtime does not support network-level interception (e.g. some
   rootless-Podman + pasta/slirp4netns setups where `CAP_NET_ADMIN` is
   unavailable inside the network namespace).
2. The proxy must distinguish traffic by container identity, which iptables
   cannot do without per-container marking.
3. The proxy must apply per-application policy that the app itself negotiates
   (e.g. a Go binary that reads `GONOSUMCHECK`).

In all other cases, prefer a lower-level mechanism so the application does not
need to know about the proxy.

## containers.conf: the rootless-Podman sweet spot

Podman 4.0+ reads `~/.config/containers/containers.conf` (or the system path
`/etc/containers/containers.conf`). The `[engine]` section accepts an `env`
key that injects env vars into **every container Podman starts**, regardless of
what the launcher code does:

```toml
[engine]
env = [
  "HTTP_PROXY=http://proxy:3128",
  "HTTPS_PROXY=http://proxy:3128",
  "http_proxy=http://proxy:3128",
  "https_proxy=http://proxy:3128",
  "NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,tillandsias-git,10.0.42.0/24",
  "no_proxy=localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,tillandsias-git,10.0.42.0/24",
]
```

With this in place:
- The launcher Rust code removes all proxy env var injection.
- A new container added tomorrow gets proxy routing automatically.
- `NO_PROXY` is maintained in one file, not scattered across every `fn build_*_run_args`.

**Trade-off**: This affects ALL Podman containers the user runs, not just
enclave containers. For Tillandsias, which owns a dedicated rootless Podman
user session (`tillandsias` service account), this is acceptable — see
`cheatsheets/runtime/dedicated-service-account-podman.md`.

## iptables TPROXY: the fully transparent approach

TPROXY intercepts packets at the kernel level before they reach the destination
socket. The application sees a normal TCP connection to the original destination
IP; Squid reads the original destination from `IP_TRANSPARENT` socket option
and handles it transparently.

### Squid config for TPROXY

```squid
# Replace the forward-proxy port with an intercept port:
http_port 3128 intercept
https_port 3129 intercept ssl-bump \
    tls-cert=/etc/squid/certs/intermediate.crt \
    tls-key=/etc/squid/certs/intermediate.key \
    generate-host-certificates=on
```

### iptables rules (on the bridge gateway)

```bash
# Redirect HTTP from all containers on the enclave bridge to Squid
iptables -t nat -A PREROUTING -i tillandsias-enclave \
    -p tcp --dport 80 -j REDIRECT --to-port 3128
# Redirect HTTPS
iptables -t nat -A PREROUTING -i tillandsias-enclave \
    -p tcp --dport 443 -j REDIRECT --to-port 3129
# Don't redirect traffic that is already from the proxy container
iptables -t nat -A PREROUTING -s <proxy-container-ip> -j ACCEPT
```

### Feasibility in rootless Podman

Rootless Podman uses pasta or slirp4netns to implement the user-mode network
stack. The host-side bridge (netavark) is created in a rootless network
namespace. To set iptables NAT rules:

1. The process must have `CAP_NET_ADMIN` and `CAP_NET_RAW`.
2. In rootless Podman the network namespace is owned by the user; iptables
   inside it is possible with `newuidmap`/`newgidmap` and the right
   capability grants, but not automatic.
3. The proxy container itself could run with `--cap-add NET_ADMIN` and set up
   iptables rules in the enclave namespace — but that requires the proxy to be
   the gateway for all other containers, which netavark does not configure by
   default.

**Action required**: see plan packet `enclave-transparent-proxy-feasibility`
(order 99) for the feasibility investigation before implementing TPROXY.

## Common pitfalls

- **Redundant injection drift**: `build_stack_common_args` already sets proxy
  env vars. Adding them again in `build_git_run_args`, `build_inference_run_args`,
  etc. creates multiple sources of truth. Inconsistencies in the `NO_PROXY`
  list have already appeared (git container has a shorter list than
  `ENCLAVE_NO_PROXY`). Rule: inject exactly once, in `build_stack_common_args`.

- **Short NO_PROXY list**: When a container is given a shorter `NO_PROXY` than
  the canonical `ENCLAVE_NO_PROXY`, internal services may be routed through the
  proxy — which then refuses them because they are not on the allowlist. This
  causes silent failures.

- **--mirror in post-receive hooks**: `git push --mirror` would delete every
  branch GitHub has that the enclave mirror lacks. Always use explicit
  per-refspec push. See `images/git/post-receive-hook.sh`.

- **Proxy env vars in the proxy container itself**: The Squid container should
  NOT have `HTTP_PROXY` set — it is the proxy, not a client.

## See also

- `runtime/enclave-network.md` — network topology
- `runtime/networking.md` — forge external access overview
- `runtime/squid-cache-peer-routing.md` — *.localhost peer routing
- `utils/podman-secrets.md` — secret injection patterns
