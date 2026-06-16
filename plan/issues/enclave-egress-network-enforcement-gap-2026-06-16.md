# Enclave egress isolation is proxy-cooperative, not network-enforced — 2026-06-16

Status: ready (work packet below)
Discovered by: `/advance-work-from-plan` (linux, cycle while investigating the
cycle-1 triage of `2026-06-16-network-isolation-regression.md`)

## Summary

Forge containers' "cannot reach the external internet" guarantee is enforced
**only cooperatively**, via `HTTP_PROXY`/`HTTPS_PROXY` env vars pointing at the
allowlisted squid proxy. The `tillandsias-enclave` bridge network is **not**
`--internal`, so it has normal NAT egress. Any process inside the forge that
ignores the proxy env (or dials a raw IP, or passes `curl --noproxy '*'`)
reaches the open internet directly, bypassing the proxy domain allowlist.

This **corrects the cycle-1 triage** which rejected
`2026-06-16-network-isolation-regression.md` as "not reproducing." That
rejection was based on the diagnostics `external_curl` probe and
`litmus-ephemeral-guarantee`, **both of which only test the cooperative path**
(diagnostics' `curl` honors `$HTTP_PROXY`; the litmus uses `--network=none`).
Neither exercises direct egress on the live enclave network. The underlying
concern is real; it is not a flapping regression but a standing architectural
property: there is no network-level egress deny.

## Evidence (reproducible, 2026-06-16, forge v0.3.260616.2)

Live runtime from a clean `tillandsias --init` (forge image +
`tillandsias-enclave` network present):

```
$ podman network inspect tillandsias-enclave --format '{{.Internal}}'
false

# container on the enclave network, plain entrypoint, honoring proxy env absent:
$ podman run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    --network=tillandsias-enclave --entrypoint=/bin/sh <forge-img> \
    -c 'curl --connect-timeout 6 -s -o /dev/null -w "HTTP=%{http_code}" https://example.com'
HTTP=200            # reached the internet directly

# explicit proxy bypass, raw IP:
$ ... -c 'curl --noproxy "*" ... https://example.com'   -> HTTP=200
$ ... -c 'curl --noproxy "*" ... https://1.1.1.1'        -> HTTP=301
```

Mechanism (code/config):
- `crates/tillandsias-core/src/container_profile.rs:381-397` — forge profile
  sets `HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy` → squid; this is
  the *only* egress restriction on the forge container.
- `images/proxy/squid.conf`, `images/proxy/allowlist.txt` — proxy enforces a
  domain allowlist (cooperative; only binds proxy-aware traffic).
- Enclave network is created without `--internal` (init log:
  `podman network create --driver bridge --subnet 10.0.42.0/24
  tillandsias-enclave`), so the bridge NATs to the host's uplink.
- The proxy container is already dual-homed
  (`Some("tillandsias-enclave,bridge")`, container_profile.rs:206-207), so it
  has its own external leg for allowlisted fetches.

## Work Packet: enclave/network-level-egress-deny

- id: `enclave/network-level-egress-deny`
- type: fix
- title: Enforce forge egress at the network layer (make enclave `--internal`, route allowlisted egress only via the dual-homed proxy)
- owner_host: linux
- status: ready
- estimated_hours: 4
- capability_tags: [rust, podman, networking, security, enclave]
- depends_on: []
- owned_files:
  - crates/tillandsias-core/src/container_profile.rs
  - crates/tillandsias-headless/src/main.rs  # enclave network creation site
  - openspec/litmus-tests/
  - openspec/specs/enclave-network/spec.md
- next_action: >
    Create `tillandsias-enclave` with `--internal` so forge containers have no
    NAT route off-host, while the dual-homed proxy (already on
    `tillandsias-enclave,bridge`) remains the single allowlisted egress path.
    Verify the forge still reaches proxy/inference/git-service over the internal
    network and that allowlisted HTTP(S) through the proxy still works, while a
    direct `curl --noproxy '*'` to an external host/IP now fails. Confirm DNS
    for in-enclave aliases still resolves under `--internal`.
- acceptance_evidence:
  - "On a clean init, a container on tillandsias-enclave with a direct (--noproxy) external curl FAILS (no route / timeout)."
  - "Allowlisted egress through the proxy still succeeds; forge→proxy/inference/git-service still work."
  - "`./build.sh --ci-full --install` + `tillandsias --init --debug` stay green; forge lane still runs."
  - "A new litmus pins direct-egress-denied on the live enclave network (not --network=none)."
- fallback_when_blocked: >
    If `--internal` breaks a legitimate in-enclave path (e.g. the proxy's own
    bootstrap or DNS), document the exact dependency and instead pursue an
    nftables/netavark egress-drop applied to the forge container's veth, keeping
    the proxy's leg open. Record findings before yielding.
- litmus_caveat: >
    Do NOT add a litmus that asserts direct-egress-denied until the fix lands —
    it would fail the build gate today (egress currently succeeds). The new
    litmus is part of the fix's acceptance, committed together with it.
- events:
  - type: discovered
    ts: "2026-06-16T11:10:00Z"
    agent_id: "linux-macuahuitl-claude-opus-20260616T093524Z"
    host: linux
    note: >
      Empirically confirmed direct egress from an enclave container reaches the
      internet (HTTP 200) on forge v0.3.260616.2; enclave network internal=false.
