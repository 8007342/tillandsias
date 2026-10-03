# Design — fleet-wan-rendezvous

Sources for every external fact: `plan/issues/fleet-wan-rendezvous-design-2026-10-03.md`
(§ numbers below refer to it). Operator rulings are numbered there; this
file states the decisions that follow from them.

## Layers

```
L3  status.tlatoani.net (static page + one roster read)       read-only
L2  per-service leases + floating names                       fenced by the DO
      git-mirror.fleet.tlatoani.net  local-experts.fleet.…
L1  signed announcements -> roster (one Durable Object)       rendezvous.tlatoani.net
      failsafe: tillandsias-rendezvous.<acct>.workers.dev     LAN: mDNS hints (1506-7tq4)
L0  host identity: Vault-held keys, public halves in plan/fleet/peers/<host>.yaml
      admitted by the operator's --github-login + --cloudflare-login + a landed
      record (enrollment only; connections trust the pinned CA)
================= control plane above (KB/day) =================
DATA  host-to-host (SSH / git mirror / experts), trusted through per-host CAs:
        same host -> LAN direct (primary) -> off-LAN over Cloudflare Mesh (v1)
        -> direct IPv6 WAN (later, goal 1548-v453)
      downloads, ISOs, container images: plain internet, never Mesh
```

## Decision 1 — One Worker, one SQLite Durable Object, alarms only

- Worker `tillandsias-rendezvous`, Custom Domains `rendezvous.tlatoani.net`
  and `status.tlatoani.net`, `workers_dev = true` for the failsafe; static
  assets: the OAuth relay page at `/tillandsias/cloudflare/callback` and the
  status page.
- One Durable Object `idFromName("fleet")`, SQLite backend (the only one on
  Free). Tables: `hosts(host, announce_pub, last_seen, slots_bitmap_7d,
  addrs, attrs, seq)`, `leases(service, holder, epoch, expires_at, since,
  handoff_requested)`, `dns(name, content, written_at, epoch)`,
  `revocations(fp, notice, ts)`.
- **No `setTimeout`/`setInterval` in the DO, ever.** One alarm at the
  nearest lease expiry, re-armed in `alarm()`. A timer makes the object
  non-hibernateable and is billed up to 140 s per wake (design note §1). A
  fixture greps the Worker source for the two identifiers and fails.
- Language: the canonical-bytes encoder, the lease state machine and the
  score live in ONE pure Rust crate (`crates/tillandsias-fleet-core`, no
  I/O) compiled natively for hosts and the fake, and to wasm for the Worker
  (workers-rs). The DO is a thin adapter; the fake rendezvous wraps the same
  core, so a fixture green against the fake exercises the logic the DO runs.
  The real-DO arm is one recorded smoke run, not a gate.

## Decision 2 — Signed announcements, no Zero Trust

- Request: `POST /v1/heartbeat` with body `{v:1, host, seq, ts, addrs:[…],
  attrs:{class_declared, substrate, ram_gib, disk_free_gib, os},
  renew:[service…], acquire:[service…], reachability:{peer:ts…}}` and header
  `Tillandsias-Sig: ed25519=<b64 sig over canonical(body)>`.
- Canonical bytes: sorted-key JSON with no whitespace, produced by
  `fleet-core` on both sides; a fixture asserts host and wasm produce
  identical bytes for 1,000 random bodies.
- Deploy: `tillandsias fleet deploy-rendezvous` (operator, once, with the
  Cloudflare bundle's Workers + DNS scopes) uploads the Worker; the DNS token
  is set by the operator as a Worker secret.
- The DO verifies against `hosts.announce_pub`, seeded only from landed peer
  records: `tillandsias fleet publish-roster` (requires the Cloudflare
  bundle; rerun on every peer-record change) uploads the tree's announce
  keys, CA public keys and `services.yaml`; an
  unknown key is `401 refused:rendezvous:unknown-host`, stores nothing.
- Replay: `|ts − now| ≤ 300 s` and `seq` strictly increasing per host.
- The DO records the observed `CF-Connecting-IP` beside the claimed
  addresses; a claimed address set that excludes the observed one is kept but
  flagged `addr-unobserved` in the roster.
- Response: the signed roster (DO-held Ed25519 key, public half in the tree
  at `plan/fleet/rendezvous.pub`), so a host can cache it and later prove to
  itself it was not forged by a network path.

## Decision 3 — Per-service lease, measured availability, affinity

Constants (operator ruling 4): `HEARTBEAT = 900 s`, `LEASE_TTL = 3600 s`,
`MIN_PRESENCE = 4 h` (16 consecutive heartbeats, no gap > 1800 s),
`OBSERVATION_MIN = 24 h` before class > transient.

- `availability_7d` = present slots / 672; `class_measured` = 2 if ≥ 0.95,
  1 if ≥ 0.60, else 0; `class_effective = min(class_declared,
  class_measured)`.
- Score tuple (descending): `class_effective`, reachability bucket,
  substrate (bare 2 / guest 1), `floor(log2 ram_gib)`,
  `floor(log2 disk_free_gib)`, os (Fedora-family 1), host id. Buckets so
  jitter never reorders.
- Affinity: `plan/fleet/services.yaml`:
  ```yaml
  services:
    git-mirror:    {preferred: [macuahuitl], eligible: any, min_presence: 4h}
    local-experts: {preferred: [macuahuitl], eligible: any, min_presence: 4h}
    status:        {preferred: [], eligible: any, min_presence: 4h}
  ```
  The DO receives it with `publish-roster` (it is tree data, like the keys).
- Acquire rules, evaluated in one DO event (atomic):
  1. renew: caller is holder and lease live → `expires_at = now + TTL`.
  2. vacant (no holder or expired): grant to the caller iff the caller is
     eligible and no OTHER eligible present host outranks it (preferred
     first, then score); else refuse with `refused:lease:outranked:<host>`.
  3. occupied: a caller that is preferred-and-the-holder-is-not, or has
     strictly higher `class_effective`, sets `handoff_requested`; the holder
     sees it on its next renew response and releases; never an immediate
     steal.
  New holder → `epoch += 1`, DNS rewrite (Decision 4), alarm re-armed.
- Failover bound: ≤ TTL + HEARTBEAT = 75 min; accepted by ruling 4.

## Decision 4 — DNS is written by the DO only

- Token: zone-scoped `Zone > DNS > Edit` on `tlatoani.net`, stored as Worker
  secret `CF_DNS_TOKEN`; no host holds a DNS token.
- Records: `<host>.fleet.tlatoani.net` AAAA = the host's observed global
  address (written on change only); `<host>.mesh.fleet.tlatoani.net` A =
  the reported Mesh IP; `<service>.fleet.tlatoani.net` and
  `<service>.mesh.fleet.tlatoani.net` CNAME to the holder's two names, plus
  TXT `epoch=<n> holder=<host>` (as the fleet-rendezvous spec delta states);
  all `proxied: false`, TTL 60. Batch endpoint when more than one record
  changes. Per-host public records are under operator review (design note
  §5a): until ruled, none are written for transient hosts.
- On vacancy the service record is NOT deleted; its TXT gains `stale=<ts>`
  so clients fall back without a resolution failure.

## Decision 5 — What the holder does, and what is fenced

| duty | fenced? | two holders | no holder |
|---|---|---|---|
| service DNS name | yes, by the DO itself | impossible | record kept with `stale=` |
| status page | yes, the DO renders from its own state | impossible | page shows last update and age |
| git-mirror | no — every write is acknowledged only after GitHub accepts | harmless | hosts use their local mirror → GitHub, loudly |
| local-experts | no — read-only answers | harmless | hosts use their local experts, loudly |
| signing certificates | never a holder duty | — | — |

Because every fenced duty is performed by the DO, hosts never need to
present an epoch to anyone; the epoch is reported for diagnosis.

## Decision 6 — Trust (fleet-trust)

- Operator ruling 14: `--github-login` (2FA) and `--cloudflare-login` gate
  ENROLLMENT only. Connection-time trust is the CA pinned in the peer record
  and never a live login or token check — a lapsed token breaks neither SSH
  nor the experts. Logout / `fleet leave` removes the record; removal is the
  revocation.
- `plan/fleet/owner.yaml`: `{github_user_id: <numeric>,
  cloudflare_user_sha256: <hex of sha256(salt || user_id)>, salt: <hex>}`;
  written once by the first `fleet enroll` on a work ref, landed by the
  normal flow.
- `plan/fleet/peers/<host>.yaml`: `host`, `announce_pub` (Ed25519),
  `noise_pub` + `noise_fp` (1506-32k5), `ssh_host_ca_pub`,
  `ssh_user_ca_pub`, `class_declared`, `substrate`, `admitted: {date,
  by: cloudflare-login}`.
- `tillandsias fleet enroll`: (1) GitHub bundle present and `GET /user`
  id equals `github_user_id`, AND Cloudflare bundle present and its userinfo
  id hashes to `cloudflare_user_sha256` (the first enroll writes both pins),
  else `refused:fleet:not-owner:<github|cloudflare>` and nothing minted; (2) mint the announce key in
  the host's Vault KV `secret/fleet/announce`, ensure the two ssh CA mounts
  (existing) and the Noise static (1506-32k5); (3) emit the peer record on a
  work ref. Peers trust a host only after its record is on linux-next.
- Fleet sshd: rootless `systemd --user` unit on port 48622,
  `AuthorizedKeysFile none`, `TrustedUserCAKeys` = all admitted user-CA
  pubs, `AuthorizedPrincipalsCommand tillandsias fleet principals %F %u`,
  `RevokedKeys` = KRL rendered from the tree.
- Client: one consented line `Include ~/.config/tillandsias/ssh/fleet.conf`
  in `~/.ssh/config`; the included file carries `UserKnownHostsFile` with
  one `@cert-authority <host>.fleet.tlatoani.net,<host>.local,<host> <pub>`
  per peer, `CertificateFile`, `RevokedHostKeys`, and `Host
  *.fleet.tlatoani.net` / service-name handling with `HostKeyAlias`.
- Certificates: host 7 d (renew at 3 d left), user 16 h, principal
  `til:fleet-operator:<login>`; mirror access principal
  `til:fleet-mirror:<host>` granted per host by the tree.
- Revocation: TTL first; KRL from `plan/fleet/revoked.yaml` and from removed
  peer records; a rendezvous revoke notice signed by a non-revoked admitted
  key SUSPENDS (refuses new sessions) until the tree confirms or 24 h pass,
  then lapses.

## Decision 7 — Shared git mirror as a pass-through (ruling 7)

- macuahuitl's existing per-project bare mirrors become reachable over the
  fleet sshd with a forced command admitting only `git-upload-pack` /
  `git-receive-pack` on mirror paths for `til:fleet-mirror:*` principals.
- Its pre-receive relay (`openspec/specs/git-mirror-service/spec.md`
  "Pre-receive relay verifies acknowledgement durability") is unchanged:
  one atomic push of exactly the received refs to GitHub, acknowledged only
  after GitHub accepts. Push identity (ruling 11): the shared Tillandsias
  GitHub App credential; attribution is the committer's per-host git
  identity, preserved unchanged (no commit is rewritten, no trailer added).
  Because 29 of the last 400 linux-next commits carry a non-host identity
  (design note §4), the mirror also appends the pushing host's certificate
  principal to its accountability log per relayed ref.
- Every other host's local mirror keeps serving its forges unchanged; its
  relay upstream is an ordered chain: `git-mirror.fleet.tlatoani.net` (when
  the TXT is not stale and the holder answers within 5 s) then GitHub.
  Reconcile fetch prefers the fleet mirror. Any fallback prints
  `fallback:git-mirror:<reason>` to the tray status and the log.
- Durability: a forge push is acknowledged only after GitHub accepts,
  through one mirror or two. A fixture proves an ack never precedes the
  GitHub-side ref.

## Decision 8 — Fleet experts follow the lease and index fleet refs

- The `local-experts` holder serves `expert-serve` on its fleet address,
  authenticated with certificates from each host's own Vault CA (ruling 14):
  mutual TLS where the server certificate is issued by the holder's host CA
  for `<holder>.fleet.tlatoani.net` and the client certificate by the
  caller's CA, each checked against the CA pinned in that host's peer record;
  an SSH-forwarded port with a fleet user certificate is the equivalent for
  clients without TLS. 1505-br88's shared bearer is replaced. App-level
  authentication is required regardless of the network, because Mesh
  service-token devices share one identity.
- Its index is built from its mirror and names the refs and commits it was
  built from (all `refs/heads/*` pushed through the fleet mirror in the last
  14 days plus `linux-next` and `main`); an answer's freshness envelope
  carries that ref set.
- Spokes use `local-experts.fleet.tlatoani.net`; unreachable →
  `fallback:local-experts:<reason>` and the host's own experts.

## Decision 9 — Partition and quota

- Rendezvous unreachable, or 1027/429: keep the last signed roster; renew
  attempts back off (to 00:00 UTC on 1027); fenced duties are the DO's and
  simply freeze; duplicable duties stay with the last known holder if it
  answers directly, else each host uses its local mirror/experts. Status:
  `blocked:rendezvous:unreachable:<reason>`.
- No LAN election is run for fenced duties. For discovery on the LAN the
  1506-7tq4 mDNS hints still work.

## Decision 10 — Data-path rungs (operator ruling 12)

- v1 rung order: same host → LAN direct (1506-7tq4; macuahuitl is always on
  the LAN, most hosts usually are) → **off-LAN over Cloudflare Mesh** for ALL
  host-to-host traffic (git mirror, experts, SSH), through the rootless
  sidecar of 1506-euvq / 1506-t97c enrolled by 1505-6w7d → (later, goal
  1548-v453) direct IPv6 WAN for metered or heavy cases.
- Container images, ISOs and other downloads go over the plain internet,
  never Mesh. No router pinholes and no Pi jump host in v1.
- Path choice belongs to the client: `tillandsias fleet resolve <name>`
  prints the LAN address when this host shares the holder's /64 and a 2 s
  connect succeeds, else the holder's Mesh IP, else
  `unreachable:<name>:<reason>`. ssh and git use it as a `ProxyCommand`.
- Constraint inherited from 1506-t97c: the sidecar shares the router's
  network namespace, so the fleet sshd, the mirror and the experts endpoint
  must be reachable from the Mesh through that namespace; 1548-h7qh measures
  this per substrate and its outcome gates 1548-7onc and 1548-q2fr off-LAN.
- Service eligibility requires a working egress from the candidate (the
  per-router probe of 1548-mhyk), so a half-blackholed host is never a
  holder.

## Rejected

- Cloudflare Mesh as the CONTROL plane: the Worker + DO needs only outbound
  HTTPS and keeps discovery alive when the sidecar is down. Mesh stays the v1
  off-LAN DATA rung for host-to-host traffic (ruling 12).
- Direct IPv6 WAN, router pinholes and the Pi as jump host in v1 (ruling 12;
  goal 1548-v453).
- KV for heartbeats (1,000 writes/day). A 30 s or 60 s heartbeat (ruling 4).
- A fleet CA on the leader; an offline root with intermediates (no OpenSSH
  chaining); Cloudflare Access SSH certs (Cloudflare on every login).
- VRRP/keepalived and NA-claimed floating addresses (root, L2-only, exclude
  guests). Raft/etcd (needs ≥ 3 always-on voters; reconsider with the Pi 5s).
