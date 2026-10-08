# Proposal — fleet-wan-rendezvous

Umbrella packet: `1548-9n28` (milestone, desired_release v0.6). Research and
decision basis: `plan/issues/fleet-wan-rendezvous-design-2026-10-03.md`
(operator rulings 1–14 are numbered there). Answers orders 563
(`mesh-identity-plane-research`), 564 (`node-discovery-and-uptime-affinity`)
and the enrollment half of 595-6y8b; packet 1548-ym32 turns the design note
into their signed decision record.

## Why

Operator direction (2026-10-03): hosts enrolled by the operator's own
`--github-login` and `--cloudflare-login` discover each other and
automatically exchange certificate authorities, so SSH and other ordinary
connections work between hosts with trust that never depends on a live
login or on Cloudflare. Cloudflare's Worker carries the control plane
(discovery, per-service leases, DNS, status page). Host-to-host data goes
LAN-direct when hosts share the LAN (macuahuitl always does, most hosts
usually do) and over Cloudflare Mesh for the one or two laptops that are
off-LAN at a time; downloads and images never touch Mesh; direct IPv6 WAN
is a later optimisation. Leadership is per service, prefers always-on hosts
over powerful transient laptops, may take hours to move, and starts with
macuahuitl hosting a fleet-wide git mirror (read and write, GitHub stays
the source of truth, every host keeps its local mirror as a failsafe) and
the Local Experts — which then index the whole fleet's refs.

Today every host is an island: no host knows another's address or keys,
`plan/fleet/` does not exist, the Local Experts see one host's work, and
`tillandsias --init` disables container IPv6 on every Linux host through a
probe that cannot succeed (`crates/tillandsias-headless/src/main.rs:8746-8760`).

Facts from the research that decide the shape:

1. A Worker plus ONE SQLite-backed Durable Object on the Workers Free plan
   is a strongly consistent compare-and-set store with alarms; at a 15-min
   heartbeat for 10 hosts it uses about 1 % of requests and 2.2 % of rows
   written. KV (1,000 writes/day, eventual) cannot carry it.
2. A host proves itself to the Worker with an Ed25519 signature over
   canonical bytes (WebCrypto in Workers): the control plane needs no Zero
   Trust identity; Zero Trust is needed only for the Mesh data rung.
3. A DNS name maintained by the Durable Object, chosen between LAN and Mesh
   addresses by the client, is the only "floating address" that is rootless
   and works on every platform.
4. OpenSSH has no certificate chaining and Vault never exports a CA key, so
   no fleet-wide CA can follow a leader; each host's own CAs are trusted for
   that host's names only, pinned by the tree. Mesh service-token devices
   share one identity, so this application-level trust is required anyway.

## What Changes

- **ADDED** capability `fleet-rendezvous`: signed heartbeat, roster,
  per-service leases with monotone epochs, the Durable Object as the only
  DNS writer, quota behaviour (1027/429 keeps the last roster),
  `status.tlatoani.net` and the OAuth relay page as static assets, the
  `workers.dev` failsafe, a fake rendezvous every fixture runs against.
- **ADDED** capability `fleet-trust`: `plan/fleet/peers/<host>.yaml`,
  `plan/fleet/owner.yaml`, `tillandsias fleet enroll` gated on both
  operator logins, connection-time trust by pinned per-host CAs only, the
  rootless fleet sshd, rendered client trust files, revocation by record
  removal.
- **ADDED** capability `fleet-services`: per-service election with measured
  availability, score and operator affinity (`plan/fleet/services.yaml`),
  4-hour presence before takeover, the LAN → Mesh path choice, the shared
  git mirror as a pass-through with loud local fallback, fleet experts with
  certificate authentication following the `local-experts` lease and
  indexing all fleet refs, partition behaviour.
- **AMENDED by event** (no title edits): 1505-6w7d (back in scope as the
  Mesh enrollment for the off-LAN rung; not needed for the rendezvous),
  1505-br88 / 1505-wteh (the hub is the `local-experts` holder; the shared
  bearer is replaced by per-host CA certificates), 1506-euvq / 1506-t97c (ON
  the critical path for the off-LAN rung), 1505-sm2j (pointer), orders 563 /
  564 / 595-6y8b (pointer to 1548-ym32).
- **Fixed**: `is_ipv6_functional` (1548-mhyk), per-router tolerant.
- **Goals filed, not v1**: direct IPv6 WAN (1548-v453), the Pi as an
  enrolled Fedora aarch64 host (1548-y56i).

Nothing about the GitHub bundle, the per-host mirror's forge-facing
behaviour or its relay contract changes.

## Impact

- Specs: three new capabilities (deltas under `specs/`). The shared mirror
  reuses `git-mirror-service`'s pre-receive relay requirement unchanged; the
  upstream chain is stated as an additive requirement in `fleet-services`.
- Code (by packet): a new pure crate `crates/tillandsias-fleet-core`
  (canonical bytes, lease state machine, score) shared by hosts and the
  Worker; a Worker project `cloud/rendezvous/`;
  `crates/tillandsias-headless` (`fleet enroll|leave|resolve|principals`,
  heartbeat in the resident, fleet sshd unit, trust rendering, mirror
  upstream chain); `crates/tillandsias-plan` (experts index over fleet refs,
  mTLS); `scripts/test-*.sh` fixtures.
- Operator: the Cloudflare setup checklist in the design note §5 (OAuth
  client and redirect URLs including the relay on `rendezvous.tlatoani.net`,
  Zero Trust org with Mesh, `workers.dev` subdomain, the zone-scoped DNS
  token as a Worker secret); the Pi's router-advertisement fix (1548-i07i).
- Out of scope: bulk data over any Cloudflare product; Cloudflare Tunnel to
  the public internet; a Raft quorum; router pinholes; the aarch64 build.
