# Proposal — app-networks

Epic: `1800-gjqq` (desired_release v0.6, priority p2 — below the v0.5 p1
fixes). Research and experiment children: `1800-b2gb`, `1800-cp93`,
`1800-zk9i`. First build slices: `1800-er9t`, `1800-d29n`, `1800-sdgk`,
`1800-seg8`, `1800-pj2x`. Related rows: `1794-rf3a` (the rootful
loopback-publish finding and its in-guest forward, NOT redesigned here),
`1651-5t7n` (the per-window browser forwarder network — the existing
throw-away-network precedent), `1506-7tq4` (LAN rung, mDNS hints),
`1506-euvq` (WARP sidecar in the router's netns), `1548-9n28` (fleet WAN
rendezvous milestone), `1548-v453` (direct IPv6 WAN goal), `1548-mhyk`
(the `--init` IPv6 probe).

## Why

Operator direction (2026-10-19): research a SECOND network for the router,
so a user can say "run this app locally without internet access" or "run
this app locally with internet access to the safe lists", and Tillandsias
creates the routing and rules dynamically — throw-away little networks that
live as long as the launched app, aligned with the ephemeral/idempotent
philosophy. The same throw-away segments should help tune the mesh between
Tillandsias nodes, using IPv6 (ULA, floating addresses, virtual segments)
between nodes since no IPv4 compatibility is needed there, with Cloudflare
for discoverability and coordination and LAN detection where possible.

SOURCE READ (2026-10-19, trunk `4e4fd5925`):

- There is ONE shared `--internal` network, `tillandsias-enclave`
  (`main.rs` `fn ensure_enclave_network`), and ONE NAT leg,
  `tillandsias-egress` (`fn ensure_egress_network`, a plain bridge). Only
  the proxy is dual-homed (`const ENCLAVE_EGRESS_NETS`; spec
  `network-scenarios` S3). Every forge, preview and toolchain container is
  enclave-only with `HTTP_PROXY` pointed at Squid (S2); Squid enforces ONE
  global allowlist (`images/proxy/allowlist.txt`, `acl allowlist dstdomain`)
  for everyone.
- Egress policy is therefore all-or-nothing per host: an app a forge
  launches (a `publish_local` preview, `local_web_preview.rs`
  `fn build_local_preview_run_args`) sits on the enclave with the same proxy
  env as the forge. "No internet for this app" is not expressible; neither
  is "this app may reach only these hosts".
- The throw-away-network pattern ALREADY EXISTS for browser windows
  (`browser_open.rs`: `podman network create --internal --label
  tillandsias.browser-window=<id> tillandsias-browser-net-<suffix>`, a
  per-window forwarder, `network connect` of the forwarder to the router's
  network, `network rm -f` on close). This change generalises that shape to
  apps and gives the router, not a forwarder, the second leg.
- IPv6: `--init` probes host IPv6 egress per default router and injects
  `pasta_options = ["--ipv4-only"]` when it fails (`main.rs`
  `fn auto_detect_and_configure_ipv6_workaround`); nothing creates an IPv6
  podman network. Measured on macuahuitl 2026-10-19 (podman 5.8.9,
  netavark, pasta 2026-10-02): `podman network create --internal --subnet
  fd7a:1800:1::/64` yields an IPv6-ONLY internal network (`IPv6Enabled:
  true`, no IPv4 subnet), two alpine containers ping each other by name over
  it, there is no egress (as intended), and creation takes 15 ms.
- Mesh and discovery are already designed and partly filed under
  `openspec/changes/cloudflare-login-and-fleet-vpn/`,
  `fleet-messaging-poc/` and `fleet-wan-rendezvous/`: Cloudflare Mesh via a
  `tillandsias-warp` sidecar sharing the router's netns, mDNS hints on the
  LAN, the rendezvous Durable Object as the only DNS writer. This change
  does NOT re-decide those; it adds the per-app segment as the unit those
  rungs route, and routes the IPv6 research into them.
- Rootful netavark publishes nothing into an `--internal` network (1794-rf3a,
  measured on the v56.10.18.1 macOS guest). The operator ruled the in-guest
  forward as the fix; this change takes it as a given and asks one
  further question (1800-b2gb): does a router with a second, NON-internal
  leg publish again, which would make the app network the natural place for
  that leg on rootful hosts.

## What Changes

- **ADDED** capability `app-networks`: a per-app throw-away podman network
  `tillandsias-app-<app>` labelled `tillandsias.app-network=<app>`, created
  when an app launches and removed when it stops or is reaped; three egress
  postures declared at launch — `none` (internal, no proxy env),
  `allowlist` (internal, proxy env, a per-app Squid allowlist keyed on the
  app network's source subnet), `open` (internal plus proxy env with no
  destination ACL, still through the proxy so logging and TLS policy hold —
  never a direct NAT leg); the router joins each app network as its second
  leg so the browser window and the host reach the app; orphan app
  networks are reaped at tray start and by the existing stop paths.
- **ADDED** posture **S7** to `network-scenarios`: app network + router
  second leg (the router becomes multi-homed across internal networks; it
  never gains a NAT leg).
- **MODIFIED** `enclave-network`: the router's run-argument builder is the
  one member that may be `network connect`ed to additional `--internal`
  networks at runtime; the membership guard learns the `tillandsias-app-`
  prefix.
- **ADDED** three experiments whose measurements gate the later slices:
  rootful second-leg publishing (1800-b2gb), IPv6-only app networks per
  substrate (1800-cp93), and the fleet ULA addressing plan feeding the mesh
  rungs (1800-zk9i).
- **ADDED** (operator scope addition 2026-10-19, relayed by yolanda) the
  **fleet shared services** story as its own epic `1800-p47s` — macuahuitl
  as compute host serving inference, nix cache, build server and (last,
  behind authenticated push) the git mirror to the LAN — on a host-side
  LAN discovery/trust slice `1800-54yy` (`_tillandsias._tcp`, trust only
  after the same Cloudflare-login identity is proved) and its Windows
  companion `1800-67gq` (the tray announces for the NAT-hidden WSL VM).
  Design §8.
- NOT in this change: a new VPN product, a redesign of 1794-rf3a's in-guest
  forward, a direct NAT leg for any app, or host firewall rules.

## Impact

- Code: `crates/tillandsias-headless/src/app_network.rs` (new), `main.rs`
  (`build_router_run_args`, network constants, reap at start),
  `local_web_preview.rs` (launch takes a posture), `toolchain_exec.rs`
  (same), `images/proxy/squid.conf` + a generated per-app ACL include,
  `scripts/lua/check-enclave-membership-documented.lua`.
- Specs: `app-networks` (new), `network-scenarios` (S7), `enclave-network`
  (router connect rule).
- Fixtures: podman-shim Lua/cargo fixtures per slice; live arms recorded on
  the epic.
