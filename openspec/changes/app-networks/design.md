# Design — app-networks

Research date 2026-10-19. Every external fact below is marked **verified**
(read from the cited page or measured on a named host) or **inferred**
(reasoned, needs the named experiment). Code is cited by symbol.

## 1. Shape

```
host / guest
  tillandsias-egress (NAT bridge)  ── proxy (Squid) ── tillandsias-enclave (--internal)
                                                         │ forge, git, vault, inference, router …
                                     router (Caddy) ─────┤
                                        │ second legs (network connect, one per live app)
                                        ├── tillandsias-app-<a>  (--internal)  app a   egress=none
                                        ├── tillandsias-app-<b>  (--internal)  app b   egress=allowlist(acl b)
                                        └── tillandsias-app-<c>  (--internal)  app c   egress=open
                                            each: label tillandsias.app-network=<app>, subnet from a
                                            per-host ULA /48 (IPv6-first, 1800-cp93) or podman's IPv4 pool
  browser window net (1651-5t7n) ── forwarder ── router   (unchanged)
```

Rules that hold in every posture:

- An app container is on exactly ONE network, its own `tillandsias-app-<app>`,
  and that network is always `--internal`. "Internet" is only ever reached
  through the proxy, so the Squid log, TLS bump policy and the global
  no-bump list keep applying. There is no posture that gives an app a NAT
  leg; `open` means "no destination ACL", not "no proxy".
- The router is the only container with legs on several internal networks
  (enclave + each live app network). It never has an egress leg. Its
  `strict_sni_host` binding and the hostname-route table are what make the
  app reachable from the browser window and from the host's published port.
- The proxy reaches an app network only when the posture needs it
  (`allowlist`, `open`): it is `network connect`ed for the app's lifetime
  with a per-app ACL keyed on the app network's subnet. For `none` the
  proxy is not connected and no proxy env is injected — the app cannot even
  ask.
- Lifecycle: created immediately before the app's `podman run`, removed
  with `network rm -f` by the same stop path that removes the app, and
  reaped at tray start by label (`podman network ls --filter
  label=tillandsias.app-network`) when no container is attached. Measured
  cost: `network create` 15 ms on macuahuitl; `network rm` refuses while a
  container is attached unless `-f` (both **verified** 2026-10-19).

## 2. Egress postures

| posture | app network | proxy connected | proxy env in app | Squid ACL for the app's subnet |
|---|---|---|---|---|
| `none` | `--internal` | no | none; `NO_PROXY` irrelevant | n/a (no path exists) |
| `allowlist` | `--internal` | yes | `HTTP_PROXY`/`HTTPS_PROXY` → proxy | `acl app_<id>_src src <subnet>` + `acl app_<id>_dst dstdomain` from the app's list; allow only the pair; the global allowlist still applies as a ceiling unless the operator widens it |
| `open` | `--internal` | yes | same | `acl app_<id>_src src <subnet>` → `http_access allow app_<id>_src` before the global allowlist deny; no-bump list still honoured |

Squid reads the per-app ACL from a generated include
(`/etc/squid/apps.d/<id>.conf`, bind-mounted from the host state dir) and is
asked to `-k reconfigure` on every app start/stop. **Inferred, settled by
1800-sdgk's fixture:** Squid 6 reconfigure keeps existing connections and
takes under a second; if it proves disruptive, the alternative is a
second Squid instance per posture, which is heavier and not preferred.

Why not `--route`, `--opt isolate`, or host firewall rules: netavark's
`--route` lives in the container netns and a `CAP_NET_ADMIN` process can
change it (**verified**, podman-network-create(1)); host firewall rules are
exactly what rootless pasta and the guest VMs make non-portable. Keeping the
boundary at "is the proxy on this network at all" is the one rule that reads
the same on every substrate.

## 3. Per-platform feasibility

| | Linux (rootless, netavark + pasta) | macOS guest (vz, rootful) | Windows WSL guest (rootful) |
|---|---|---|---|
| per-app `--internal` network | **verified** works today (browser windows already do it) | **inferred** same code; create/rm are netavark, not pasta | same as macOS |
| router second leg via `network connect` | **verified** pattern (browser forwarder is connected to the router's network today) | **inferred**; 1800-b2gb measures it | same |
| host reaches app through router's published port | **verified** (pasta forwards `-p 127.0.0.1:` into internal networks, 1794-rf3a) | DEAD today for the internal-only router (1794-rf3a); the ruled fix is the in-guest forward to the router's enclave IP. **Open question for 1800-b2gb:** does a second NON-internal leg on the router restore netavark's DNAT? A maintainer reply on the podman list says internal networks get no firewall rules at all, so publishing works rootless only through pasta's user-space forwarder (**verified** from the list archive; the second-leg workaround is **inferred**, not maintainer-stated) | same question; WSL additionally has `networkingMode=mirrored` (Win11 22H2+) which changes how the guest's ports appear on the host (**verified**, learn.microsoft.com/windows/wsl/networking) |
| IPv6-only app subnet | **verified** on macuahuitl: `--internal --subnet fd7a:1800:1::/64` → IPv6-only, name resolution and ping between members work, no egress; NOTE busybox `nslookup` reported "Message too large" against aardvark on v6 while the libc resolver worked — 1800-cp93 checks Caddy's dial | **inferred** identical (same netavark); gvproxy's IPv6 handling for published ports is **unknown** (no doc or issue found) — measured by 1800-cp93 | same; mirrored mode gives the guest IPv6 (**verified**) |
| proxy on an IPv6-only app net | **inferred**: Squid listens on `[::]` already? — 1800-cp93 checks `http_port` binding and that `acl … src fd..::/64` is accepted | same | same |
| aardvark DNS inside internal networks | **verified** that upstream has been fixing DNS firewall rules on internal networks (podman #22807 closed by "bridge: add DNS firewall rules for internal networks"; netavark #1051 closed Aug 2026) — so behaviour differs by netavark version; the guest images pin theirs | podman machine historically had DNS trouble on internal networks via gvproxy (`use_port_mapping` in `container_profile.rs` exists for that reason) — re-measure | same |

## 4. IPv6 between nodes (the mesh side)

Facts that shape the recommendation:

- Cloudflare Mesh (ex WARP Connector) routes IPv6 CIDRs only when the
  device profile uses MASQUE, not WireGuard; advertising CIDR routes needs
  `net.ipv6.conf.all.forwarding` and `accept_ra` on the node; Linux minimum
  is 3 vCPU / 1 GB for the client (**verified**, developers.cloudflare.com
  cloudflare-mesh/get-started). Headless enrollment is `warp-cli connector
  new <token>` (**verified**). The rootless sidecar launch that gets a TUN
  was already measured on yoga 2026-10-03 (`images/warp/Containerfile`).
  The 3-vCPU floor matters for esme/macneo (floor tier): Mesh is for the
  router host that holds a lease, not for every floor host.
- Cloudflare Tunnel CIDR routes "may be private or public" (**verified**,
  cloudflare-one/networks/routes); whether a ULA `fd..::/64` route is
  accepted is **unknown** and is one arm of 1800-zk9i's checklist.
- Tailscale/Headscale give every node a stable `fd7a:115c:a1e0::/48`
  address and can run userspace without root but then expose only a SOCKS
  proxy, not an interface (**inferred**, not re-verified); plain WireGuard
  routes a /64 per peer through `AllowedIPs` (**inferred**, standard). These
  are comparison points only — the operator's 2026-09-29 ruling is
  Cloudflare FREE, and `fleet-wan-rendezvous` already fixes the rung order
  (same host → LAN direct → Mesh → direct IPv6 WAN later, 1548-v453).
- LAN discovery: mDNS/link-local multicast needs the same L2 segment. A
  vz NAT guest does not see LAN multicast and bridged vz needs the
  restricted `com.apple.vm.networking` entitlement (**inferred**); WSL2
  mirrored mode supports multicast and mDNS (**verified**). Rootless pasta
  does not forward multicast (**inferred**). So discovery runs on the HOST
  side (the tray), as 1506-7tq4 already places it, and the guest only
  consumes hints.

Recommended addressing plan (the deliverable of 1800-zk9i, stated here as
the hypothesis to confirm or refute):

- One fleet ULA `/48` generated per RFC 4193 at `fleet enroll` and recorded
  in `plan/fleet/owner.yaml`; one `/56` per host (`plan/fleet/peers/<host>.yaml`
  gains `ula_prefix`); one `/64` per live app from the host's `/56`, chosen
  by the app network module and released with the network. 256 apps per
  host, 256 hosts per fleet — generous for a personal fleet.
- A "floating" service address is a `/128` inside the HOLDER's `/56`,
  moved by the rendezvous lease (the DO already owns DNS writes): the
  floating thing is the NAME, with the A/AAAA switched by the lease holder,
  which is what works rootless on every substrate (fleet-wan-rendezvous
  decision 3). Interface-level floating (`ip -6 addr add … nodad` plus an
  unsolicited NA) is a LAN-only optimisation and is not the v1 mechanism.
- A per-app `/64` becomes mesh-reachable by advertising it from the
  holder's router netns: over Mesh via a MASQUE profile CIDR route, over the
  LAN via the host's own routing table. Measured by 1800-zk9i's arms, not
  assumed.

## 5. Security boundary

Must never be reachable from an app container, in any posture: the host
network, the Vault container, the git mirror, the inference service, other
apps' networks, other projects' routes, the forge itself. The mechanisms:

- The app network is `--internal` and the app has no other network; its
  only neighbours are the router (and, for allowlist/open, the proxy).
- The router's hostname routes answer only this project's hosts and
  `strict_sni_host` binds Host to SNI (as for browser windows).
- The proxy's per-app ACL is keyed on the app network's SOURCE subnet, so
  an app cannot borrow another app's allowlist; `*.localhost` peer routing
  stays limited to the router.
- Inter-network isolation: netavark's `isolate` option defaults to
  `strict` in current docs (blocks traffic between bridges) — **verified**
  from podman-network-create(1) but the default on the pinned 5.x may
  differ, so 1800-er9t's live arm asserts app-a cannot reach app-b's
  address and the enclave's vault alias.
- The router keeps NO egress leg; a guard (extending
  `check-enclave-membership-documented.lua`) refuses `network connect` of
  any `tillandsias-egress` into a router or app container.

## 6. Phased approach

1. **Measure (v0.6, research, parallel):** 1800-b2gb rootful second-leg
   publishing matrix; 1800-cp93 IPv6-only app networks per substrate
   (Linux already green); 1800-zk9i the addressing plan and the Cloudflare
   ULA route arm.
2. **Build the lifecycle (v0.6):** 1800-er9t `app_network` module with the
   label, create/rm/reap and the isolation live arm; 1800-d29n the router's
   second leg and spec deltas (S7, enclave-network rule, membership guard).
3. **Build the postures (v0.6):** 1800-sdgk per-app Squid ACLs and the
   `none`/`allowlist`/`open` table; 1800-seg8 the posture in the launch
   API (`publish_local`, toolchain sessions) and the tray/agent status
   line.
4. **IPv6-first (v0.6/v0.7, gated on 1800-cp93):** 1800-pj2x app subnets
   from the host's ULA `/56`; then the mesh rungs in `fleet-wan-rendezvous`
   route per-app `/64`s (filed there, not here).

## 8. Fleet shared services (scope added by the operator, 2026-10-19)

macuahuitl is the compute host (GPU, RAID0, 1GbE shared with lenovinha on
one segment; the other hosts are on WiFi 6/7, so LAN-direct beats
Cloudflare); Raspberry Pis later run low-power always-on services. Order,
easiest first (yolanda's survey): inference, nix cache, build server, git
mirror. Epic `1800-p47s`; every slice depends on the discovery/trust slice
`1800-54yy`.

The networking core these share with the app networks:

- **Discovery is host-side.** The tray announces and browses
  `_tillandsias._tcp` (TXT: host, services, the Cloudflare-login identity
  proof's fingerprint) on the LAN; guests never multicast. Under WSL2's
  default NAT the VM is invisible on the LAN, so the Windows tray announces
  on the VM's behalf and forwards (`1800-67gq`, pickup windows). mDNS hints
  are the same hints `1506-7tq4` consumes; a hint is TRUSTED only after the
  peer proves the same Cloudflare-login identity (the fleet-trust
  enrollment record), which also covers Ollama's missing auth.
- **The enclave reaches ONE LAN host per service, never the LAN.** An
  enclave member keeps posture S2; the proxy gains a per-service ACL
  (`acl lan_<service>_dst dst <peer ip>` + port) and the container's
  service env (`OLLAMA_HOST`, the nix substituter URL) points at a router
  alias (`inference`, `nix-cache`) that the router forwards to the LAN peer
  — the same "the router is the second leg" rule as §1, so the forge's view
  (`http://inference:11434`) does not change when the service moves hosts.
  The LAN peer's address comes from the discovery record, re-resolved on
  each announce; when the peer disappears the alias falls back to the local
  container and one status line says so.
- **Per service:** inference — `OLLAMA_HOST` is a literal in
  `container_profile.rs` (two sites) and the health probe dials
  `127.0.0.1:11434` in `accel_probe.rs`; both become a resolved endpoint.
  Nix cache — already TLS with a signing key, bound to `127.0.0.1`; bind to
  the LAN address, publish the cert and public key in the discovery TXT /
  peer record, add as a substituter. Build server — no nix remote builder
  exists; `1287-w9s4` only measures sccache; the slice adds a remote-builder
  entry over the fleet sshd (`1548-u5wv`). Git mirror — LAST: `git://`
  push has no auth (322 archived, 451 pending), so it goes on the LAN only
  behind authenticated push; `1292-mzr8` keeps the Pi off the push path.

## 7. Experiments and the measurement that settles each

| unknown | settled by | measurement |
|---|---|---|
| rootful router with a second non-internal leg publishes `-p 127.0.0.1:` | 1800-b2gb | on the macOS and WSL guests: router on enclave only vs enclave + a plain bridge, `curl` the published port, both results recorded with `podman ps` and `nft list ruleset` |
| gvproxy forwards IPv6 published ports / guest has IPv6 egress | 1800-cp93 | `podman run -p '[::1]:…'` in the guest, `curl -6` from the host; `ping -6` from the guest |
| Caddy dials an IPv6-only upstream and Squid accepts `src fd../64` | 1800-cp93 | a static preview on an IPv6-only app net reaches 200 through the router; Squid `-k parse` on the generated ACL |
| Squid `-k reconfigure` is non-disruptive at app start/stop | 1800-sdgk | a long-lived download through the proxy survives ten reconfigures |
| netavark isolates app-a from app-b on the pinned version | 1800-er9t | `ping`/`curl` between two app nets fails; to the router succeeds |
| Cloudflare Tunnel/Mesh accepts a ULA `/64` route | 1800-zk9i | API call recorded with its response body |

## Operator rulings (2026-10-19)

1. **Default posture is `none`.** An app the agent launches without naming a posture gets no internet.
2. **Posture changes live, in both directions, without restarting the app.** An agent can elevate an existing app's network (`none` → `allowlist` → `open`) and downgrade it again, for example to test that one link works and then drop egress straight away. The proxy ACL for the app's subnet is swapped in place, and the app's process and connections to the router are untouched. Each change is logged as an event in the owning forge's stream.
3. **Cloudflare Mesh only on hosts that meet its floor.** Low-end (floor-tier) hosts are excluded for now and are revisited later.
4. **Raspberry Pis are deferred.** They join discovery once they are assembled and the aarch64 build exists.
5. **Trust model: discover anywhere, trust through the shared account.** Devices find each other over whatever network they share (LAN first). Two devices signed into the same Cloudflare account exchange trusted certificates over the Cloudflare mesh, and those certificates then secure their direct device-to-device traffic. That private channel should be IPv6-only.
