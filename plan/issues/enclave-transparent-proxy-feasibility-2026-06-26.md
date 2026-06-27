# Enclave Transparent Proxy: Feasibility Investigation

**Status:** `pending`
**Owner:** linux
**Date:** 2026-06-26
**Trace:** `spec:proxy-container`, `spec:enclave-network`

## Problem

The enclave proxy is a Squid **forward proxy** (port 3128, HTTP CONNECT mode).
Containers must have `HTTP_PROXY` / `HTTPS_PROXY` env vars set to use it.
Without them, outbound traffic bypasses the proxy and the allowlist.

This creates an O(N) maintenance burden: every new container is a chance to
forget the proxy env vars. The BigPickle fix in commit `c8f59e24` added proxy
vars to the git container because it was missing them — the same problem will
recur every time a new container is introduced.

The ideal solution is a **truly transparent proxy** where containers have zero
proxy configuration: they connect to the internet as normal and the kernel
silently redirects the traffic through Squid.

## Research Questions

1. Can the Tillandsias proxy container run with `CAP_NET_ADMIN` via
   `--cap-add NET_ADMIN` while the rest of the stack uses `--cap-drop=ALL`?
   Does this conflict with `--security-opt=no-new-privileges`?

2. Does the Fedora host (rootless Podman, netavark networking) expose a bridge
   interface (`tillandsias-enclave` or similar) that iptables rules can be
   applied to from a user process with the right capabilities?

3. What kernel modules are required for TPROXY (`xt_TPROXY`,
   `nf_conntrack`, `ip_tables`)? Are they present on a stock Fedora Silverblue
   host?

4. If the proxy container cannot manipulate iptables, can the **host-level**
   tray process (the `tillandsias` binary, running as the user) set up
   iptables rules in the rootless network namespace on enclave start/stop?

5. What is the minimum Squid config change to switch from forward to intercept
   mode? Can port 3128 be kept as a forward port for build-time use while a
   second intercept port handles runtime containers?

6. What breaks if we switch to intercept mode?
   - The forge's `git push` (already routed via the mirror, not through the proxy)
   - `cargo build` inside forge (must route through proxy for crates.io)
   - `vault-cli` (internal only, should be in NO_PROXY)
   - The proxy container itself (must not intercept its own outbound traffic)

## Acceptance Criteria

- Written verdict: "iptables TPROXY is feasible in our rootless Podman setup"
  or "it is not feasible, and here is why".
- If feasible: a minimal proof-of-concept iptables rule set and Squid config
  change that demonstrates traffic is transparently intercepted from a test
  container without any proxy env var.
- If not feasible: a clear recommendation for the next-best approach
  (`containers.conf` injection or another mechanism) and why it is better than
  the current per-container Rust injection.
- Finding filed in this document under `## Verdict`.

## Files to investigate

- `images/proxy/squid.conf` — current Squid config
- `images/proxy/Containerfile` — proxy container build
- `crates/tillandsias-headless/src/main.rs` — `build_proxy_run_args`,
  `build_stack_common_args`
- `cheatsheets/runtime/enclave-proxy-patterns.md` — iptables TPROXY notes

## Verdict

*(pending)*
