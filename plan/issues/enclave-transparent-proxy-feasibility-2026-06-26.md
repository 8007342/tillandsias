# Enclave Transparent Proxy: Feasibility Investigation

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-26
**Completed:** 2026-06-27T03:20Z
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

**TPROXY is NOT feasible in our rootless Podman / netavark enclave. Use `containers.conf [engine] env` injection as the canonical solution.**

### Evidence Gathered (2026-06-27, host: Fedora 44, kernel 7.0.12-201.fc44.x86_64)

**Q1 — CAP_NET_ADMIN in proxy container:**
- `--cap-add NET_ADMIN` would grant the proxy container capability to manipulate
  netfilter in its own **user namespace** only. The enclave bridge (`podman2`,
  subnet `10.0.42.0/24`) lives in the **host network namespace**.
- `--cap-add NET_ADMIN --security-opt=no-new-privileges` would conflict: `no-new-privileges`
  blocks any capability grant beyond the parent process, meaning the container
  gets an empty capability set and NET_ADMIN never lands.
- Even if granted, a rootless container's NET_ADMIN is scoped to a mapped user
  namespace; `iptables`/`nftables` rules on the host bridge interface require
  real root or a privileged network namespace, neither of which we have.

**Q2 — Bridge interface visibility:**
- `podman network inspect tillandsias-enclave` confirms: bridge `podman2`,
  subnet `10.0.42.0/24`, gateway `10.0.42.1`. The bridge IS visible in the host
  netns (`ip link list` from `podman unshare` shows it).
- But visibility ≠ writability. The `tillandsias` tray binary runs as uid 1000.
  `iptables -L` from uid 1000 returns: **`Permission denied (you must be root)`**.
  No CAP_NET_ADMIN is granted to user processes on this Fedora host.

**Q3 — Kernel modules:**
- `xt_TPROXY.ko.xz` is present (`modinfo xt_TPROXY` → success).
- `nft_tproxy.ko.xz` is also present (nftables variant).
- `nf_conntrack` and `ip_tables` are present and active (lsmod).
- The modules exist but **cannot be exploited** by a rootless user process.

**Q4 — Host-level tray process iptables:**
- Same as Q2: the tray binary is uid 1000 with no `CAP_NET_ADMIN`. Cannot
  write PREROUTING rules in the host netns. Using `pkexec`/`sudo` to acquire
  root for each enclave start/stop is fragile, non-idiomatic, and introduces
  a privilege escalation path we must not open.

**Q5 — Squid intercept mode config:**
- Squid intercept mode requires the `intercept` flag on `http_port`:
  `http_port 3130 intercept ssl-bump ...`
- A second intercept port (3130) can coexist with the existing forward ports
  (3128/3129). Port 3130 would need iptables PREROUTING to redirect all
  enclave egress → 3130 before Squid would intercept it.
- Without the PREROUTING rule, intercept mode has zero effect.

**Q6 — What breaks with intercept mode:**
- Moot, since the PREROUTING rule cannot be installed rootlessly.

### Recommendation: `containers.conf [engine] env` (Podman 4.0+)

Podman 4.0+ supports injecting env vars into **every container launched by
podman** via the user-level `~/.config/containers/containers.conf`:

```toml
[engine]
env = [
  "HTTP_PROXY=http://proxy:3128",
  "HTTPS_PROXY=http://proxy:3128",
  "NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,tillandsias-git,10.0.42.0/24",
]
```

**Why this is better than per-container Rust injection:**
- Zero per-container code. New containers get the proxy automatically.
- Applies to containers launched outside tillandsias (e.g., `podman run` in a
  forge shell or a forge agent using the Docker API).
- Survives code refactors that bypass `build_stack_common_args`.
- Managed at install/update time by `scripts/install.sh` or
  `tillandsias --init`; not scattered through image build code.
- Precedence: env vars set explicitly on `podman run --env` OVERRIDE
  `containers.conf` values, so the existing `build_stack_common_args` explicit
  injection remains a valid fallback / override during transition.

**Limitation:** The proxy address (`proxy:3128`) must be reachable before
containers.conf values are useful. During enclave startup, the proxy container
itself starts before other runtime containers and after the enclave network
exists, so the timing is correct. Build-time container launches (image builds)
that use port 3129 would also need the proxy running, which is already the case.

**Implementation:** Covered by order 107 (`enclave-proxy-centralize-injection`).
That order should:
1. Write `[engine] env` to `~/.config/containers/containers.conf` at
   `tillandsias --init` time (idempotent merge, not full overwrite).
2. Remove the duplicated per-container proxy env var injection from
   `build_stack_common_args` after the containers.conf injection is live.
3. Keep a single canonical `ENCLAVE_NO_PROXY` constant in Rust and reference
   it from both the containers.conf writer and any remaining explicit injections.

### Files referenced
- `images/proxy/squid.conf` — forward proxy on 3128/3129; intercept not viable
- `~/.config/containers/containers.conf` — existing file has `pasta_options`; engine.env to be added
- `crates/tillandsias-headless/src/main.rs` — `build_stack_common_args` has the current per-container injection
- `cheatsheets/runtime/enclave-proxy-patterns.md` — updated in order 105
