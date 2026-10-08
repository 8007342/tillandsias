# Fleet WAN rendezvous: control plane on Cloudflare, data plane direct (milestone 1548-9n28)

- classification: research + design
- filed: 2026-10-03 (linux/yoga, Silverblue 44; branch `work/fleet-wan-rendezvous` off
  linux-next `08b8862e4`)
- status: designed; packets filed under `plan/index.d/`; nothing implemented
- change: `openspec/changes/fleet-wan-rendezvous/`
- desired release: v0.6
- builds on: milestone 1505-sm2j (`plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md`)
  and milestone 1506-3xu7 (`plan/issues/fleet-messaging-poc-design-2026-09-29.md`)
- answers: order 563 `mesh-identity-plane-research` (`plan/index.yaml:11863-11901`), order 564
  `node-discovery-and-uptime-affinity` (`plan/index.yaml:11903-11935`), and the enrollment half
  of order 595-6y8b (`plan/index.yaml:12775-12800`). Packet 1548-ym32 turns this note into
  their decision record. It does not open a parallel research thread.

Register used below: **[M]** is a measurement, quoting the command that was run. **[S]** is a
source claim, citing a file and line or a URL. **[I]** is an inference and is labelled as one.
**UNVERIFIED** means the claim comes only from a secondary source, or no source could be reached.
The Cloudflare pages were fetched 2026-10-03 between 18:09Z and 18:11Z. The measurements were
taken on yoga the same day.

## Operator rulings (2026-10-03, this session, verbatim where quoted)

1. Cloudflare, not Tailscale ("ignore TailScale, prefer CloudFlare").
2. The Cloudflare layer carries the CONTROL PLANE ONLY: discovery, automatic exchange of
   certificate authorities, leader election and a status page. Bulk data ("hundreds of
   gigabytes of ISO and CLOUD images") never goes over it. This is defensive design: "I'm
   assuming the free tier will be metered at some point". The goal is "automatic exchange of
   Certificate Authorities to allow SSH and other regular connections over LAN/WAN/Internet
   without relying on Cloudflare's free service".
3. Leader election favours always-on hosts: "always-on hosts should be preferred as leaders over
   more powerful hardware that's transient, like laptops".
4. Timing: a 30 s heartbeat "is a bit too high, 60s is still kinda high"; "we can let leases go
   for like an hour"; "it's fine if a host requires several hours of uptime before taking over".
5. Leadership is per service: "metrics-driven affinity rules defined by us to encourage our
   favorite hosts to be more likely to be the leader for their elected services".
6. First elected services: macuahuitl, which is "a 24/7 on Workstation" with the strongest GPU,
   CPU and RAM, hosts a fleet-wide GIT-MIRROR and the LOCAL EXPERTS for the other hosts.
7. The shared mirror is "for read and write, but each host can failsafe to use its local
   github-mirror as they always have. Remote is the source of truth". Purpose: "the local
   experts will have context from the whole fleet, not just each individual host".
8. Admission: "login with operator operated --cloudflare-login sounds like a strong and secure
   enough gate".
9. Domains: the operator owns `tlatoani.net` on Cloudflare. The apex holds personal
   presentation material. Subdomains are used for discovery, with `status.tlatoani.net` as the
   landing page. `workers.dev` "could be a solid failsafe".
10. Network: the ISP gives the router a public IPv6 prefix; a Raspberry Pi in the router's DMZ
    runs DNS, DHCP and other services; a file server is already served on the open internet.
    The operator recalls earlier research suggesting a "virtual floating ipv6".

Later rulings (2026-10-03, relayed by the coordinator; they replace open questions 1–3 and
REVERSE the first draft's demotion of Mesh):

11. **Push identity (closed).** macuahuitl forwards pushes with the shared Tillandsias GitHub App
    credential. Every host already shares that App login, so sharing the push credential is
    accepted. Attribution is the committer's per-host git identity, preserved unchanged through
    the mirror.
12. **Host locations (closed).**
    - macuahuitl is always on the LAN, and most hosts are on the LAN most of the time, so
      **LAN direct is the primary data path**.
    - One or two laptops at a time are off-LAN. **They use Cloudflare Mesh for ALL host-to-host
      traffic in v1**: git mirror, experts and SSH.
    - Container images and other downloads go over the plain internet, never Mesh.
    - Direct IPv6 WAN (pinholes, hole punching) is a LATER optimisation for metered or heavy
      cases. v1 has no router pinholes and no Pi jump host.
    - 1506-euvq and 1506-t97c are therefore ON the critical path for the off-LAN rung, and
      1505-6w7d is back in scope.
    - The Worker + DO rendezvous stays the control plane: discovery, leases, DNS and the status
      page.
    - Rung order: same-host → LAN (1506-7tq4) → off-LAN over Mesh → (later) direct IPv6 WAN.
13. **The Pi (closed for v1): out of scope.** Today it runs Ubuntu Server with hand-run docker
    containers. The far-off goal is packet 1548-y56i: the Pi runs a Fedora 44 aarch64 cloud
    image; the operator runs `--github-login` and `--cloudflare-login` on it; it then starts its
    services with high affinity. That needs an aarch64 build. The Pi's router-advertisement
    misconfiguration stays an operator action (1548-i07i), because it breaks LAN IPv6 today.
14. **Trust at connection time (closed; the last open question).**
    - The experts, and every other host-to-host service, authenticate with certificates from each
      host's OWN Vault CA.
    - Those CA public keys are published in `plan/fleet/peers/` and the rendezvous roster, and
      pinned to that host.
    - `--github-login` (2FA) plus `--cloudflare-login` gate ENROLLMENT only.
    - At connection time trust is the pinned CA, never a live login or token check. A lapsed
      token must not break SSH or the experts.
    - Logout or revoke removes the host's record.
    - 1505-br88's shared bearer is replaced (amendment event in this commit).
    - Mesh service-token devices share one identity, so this application-level authentication is
      required regardless.

## 1. Cloudflare as control plane: what the free plan gives (research A)

### Free-plan quotas
- **Workers Free:** "a daily request limit of 100,000 requests, resetting at midnight UTC. When a
  Worker exceeds this limit, Cloudflare returns **Error 1027**." The limit is account-wide.
  CPU is 10 ms per invocation; there are 50 subrequests per request, 100 Workers per account
  and 5 Cron Triggers. [S] https://developers.cloudflare.com/workers/platform/limits/
- **Bandwidth is not metered:** "There are no additional charges for data transfer (egress) or
  throughput (bandwidth)." This applies to Workers, D1 and R2.
  [S] https://developers.cloudflare.com/workers/platform/pricing/
- **Static assets cost nothing:** "Requests to static assets are free and unlimited". The relay
  page and the status page HTML therefore use no quota.
  [S] https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/
- **KV is the wrong store:**
  - 1,000 writes a day, and "If you exceed any one of these limits, further operations of that
    type will fail with an error."
    [S] https://developers.cloudflare.com/kv/platform/pricing/
  - Eventually consistent, "up to 60 seconds or more".
    [S] https://developers.cloudflare.com/kv/concepts/how-kv-works/
- **Durable Objects are on Free, SQLite backend only:**
  - Free limits: 100,000 requests a day, which "Includes HTTP requests, RPC sessions, WebSocket
    messages, and alarm invocations"; 13,000 GB-s of duration a day; 100,000 rows written a
    day; 5 GB of storage. "Each `setAlarm()` is billed as a single row written."
    [S] https://developers.cloudflare.com/durable-objects/platform/pricing/
  - One object is single-threaded, and "a series of reads followed by a series of writes (with
    no other intervening I/O) are automatically atomic". That makes it a compare-and-set store.
    [S] https://developers.cloudflare.com/durable-objects/api/storage-api/
  - Alarms: "a single alarm at a time" per object, "guaranteed at-least-once execution", and up
    to 6 retries. [S] https://developers.cloudflare.com/durable-objects/api/alarms/
- **Hard rule: no timers inside the Durable Object.** Hibernation is possible only with no
  `setTimeout` or `setInterval`. An idle object that cannot hibernate is billed until eviction
  "after 70-140 seconds of inactivity".
  [S] https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/
  [I] At a 60 s heartbeat, one `setInterval` would cost about 19× the daily duration quota
  (research A §3). All scheduling uses alarms.

### Domains and the failsafe
- **Custom Domains need no paid plan:** "Cloudflare will create DNS records and issue necessary
  certificates on your behalf". No plan gate is stated, and the limits page lists "Custom
  domains per zone: 100" for Free.
  [S] https://developers.cloudflare.com/workers/configuration/routing/custom-domains/
  Whether Custom Domains attach on this particular account is UNVERIFIED until the first deploy.
- **The workers.dev name is chosen, not random:** it is `<worker>.<account-subdomain>.workers.dev`,
  and the account subdomain is set in the dashboard ("Select **Change** next to **Your
  subdomain**"). Set `workers_dev = true` explicitly, because it defaults to off once routes
  exist. [S] https://developers.cloudflare.com/workers/configuration/routing/workers-dev/
- **The zone is already on Cloudflare.** [M] `dig +short NS tlatoani.net` →
  `harlan.ns.cloudflare.com.`, `gwen.ns.cloudflare.com.`; the apex has no A/AAAA record today.

### Host authentication without Zero Trust
- WebCrypto in Workers supports Ed25519 sign/verify/import and X25519.
  [S] https://developers.cloudflare.com/workers/runtime-apis/web-crypto/
- So a host signs its announcement with a key pinned in the tree. The Worker verifies the
  signature itself, with no Access application, no service token and no seats.
- The alternative was rejected. Access service tokens avoid seats, but they need an Access
  application with a Service Auth policy, which means a Zero Trust organization and a cap of
  50 tokens.
  [S] https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/
  and `/cloudflare-one/account-limits/`.
  This supersedes the service-token rendezvous credential suggested in research C §1.

### DNS
- **Token:** `Zone > DNS > Edit`, scoped to the one zone.
  [S] https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- **Writes:** `PUT /zones/{zone_id}/dns_records/{id}`. A batch endpoint is available on all
  plans, with up to 200 records per batch on Free.
  [S] https://developers.cloudflare.com/dns/manage-dns-records/how-to/batch-record-changes/
- **Records must be DNS-only, so `proxied: false` is mandatory:**
  - Proxied records carry only HTTP/HTTPS and have TTL Auto (300 s), so SSH and git would not
    work through them.
  - The minimum TTL for a DNS-only record is 60 s.
  [S] https://developers.cloudflare.com/dns/manage-dns-records/reference/ttl/ and
  https://developers.cloudflare.com/dns/proxy-status/
- **API rate limit:** 1,200 requests per 5 minutes.
  [S] https://developers.cloudflare.com/fundamentals/api/reference/limits/
- **The Worker can be the only DNS writer:**
  - The token is held as a Worker secret.
    [S] https://developers.cloudflare.com/workers/configuration/secrets/
  - The Worker sees a client's real IPv6 address in `CF-Connecting-IP`, because Pseudo IPv4
    defaults to Off. [S] https://developers.cloudflare.com/network/pseudo-ipv4/
  - Hosts hold no DNS token.

### OAuth relay page
- `assets/cloudflare-relay/index.html` [S] becomes a static asset at
  `/tillandsias/cloudflare/callback` on the rendezvous host.
- The primary documentation's example registers `https://example.com/oauth/callback`, which has
  the same shape. [S] https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/
- Exact-match and loopback-acceptance rules still come only from a SECONDARY source
  (`plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md:43-52`). They must be confirmed
  on the real client form.
- Keep the client PRIVATE: "Setting a client's visibility to public is permanent."

### Mesh and metering
- Mesh traffic goes "through the nearest Cloudflare data center, not directly between devices".
  [S] https://developers.cloudflare.com/mesh/concepts/
- The account-limits page states no bandwidth cap.
- A "10 GB then $1/GB" figure exists only on third-party pages and is UNVERIFIED.
- Either way, Mesh is the wrong path for bulk data by design.
- Per ruling 12, Mesh is the v1 off-LAN rung for host-to-host traffic only: git mirror, experts
  and SSH, which are small compared with images. It runs as the rootless sidecar of
  1506-euvq/1506-t97c and is enrolled through 1505-6w7d.
- Mesh nodes get a private IP in `100.96.0.0/12`.
- [S] Every byte crosses a Cloudflare data center (`/mesh/concepts/`). That is the reason
  downloads and container images never use it.

## 2. The LAN's IPv6, measured on yoga (research B)

### The Raspberry Pi advertises a default route it does not forward
- [M] `ip -6 route show` lists two ECMP default next hops:
  - `fe80::10:18ff:fe02:2901`, the Motorola ISP gateway, MAC c8:c7:50:f0:88:16. It is also
    192.168.0.1.
  - `fe80::2ecf:67ff:fec1:3a8c`, an EUI-64 address embedding MAC 2c:cf:67:c1:3a:8c.
    `/usr/share/hwdata/oui.txt` gives that OUI as "Raspberry Pi (Trading) Ltd". It is also
    192.168.0.250.
  - A third RA source, `fe80::76ec:b2ff:fe55:1ebf` (Amazon OUI), routes only the private
    `fd15:794e:a208:1::/64` prefix and is harmless.
- [M] Flow labels were pinned so each probe took a known next hop:
  `ip -6 route get D flowlabel F ipproto ipv6-icmp` then `ping -6 -F F -c 2 -W 2 D`, for
  `D ∈ {2001:4860:4860::8888, 2606:4700:4700::1111}` and `F = 0x1..0x8`.
  - Through the Pi: 9 of 9 probes lost.
  - Through the Motorola: 7 of 7 answered.
  - The predicted next hop matched the outcome in 16 of 16 probes.
- [M] `tracepath -6 -n -m 3` on the Pi path got no reply at hops 1–3.
- [M] `curl -6 -m 20` failed 3 of 4 times to `https://ipv6.google.com/` and 1 of 4 to
  `https://one.one.one.one/`.
- [I] The Pi runs dnsmasq or radvd with a router lifetime above 0 while forwarding is off. Its
  neighbour advertisement lacks the router flag, which is consistent with that.
- Effect: roughly half of all IPv6 flows from any host on this LAN stall.
- The fix is operator work on the Pi (packet 1548-i07i): dnsmasq `ra-param=<iface>,0,0`, or
  radvd `AdvDefaultLifetime 0;`.

### Addressing
- [M] `ip -6 addr show` shows a single global address,
  `2603:8000:3303:b4ad:…/64 scope global dynamic noprefixroute`, with preferred lifetime about
  300 s and valid lifetime about 7,000 s.
- The address comes from SLAAC with an RFC 7217 stable-privacy interface ID and no temporary
  addresses.
- [M] `journalctl --since -60d | grep -oE '2603:8000:…'` finds one prefix, `2603:8000:3303:b4ad`,
  from 2026-09-18 to 2026-10-03, across 15 boots.
- The "32 bits" the operator recalled is not visible from a LAN host. The LAN carries a /64.
  The size of the router's delegation (/64 or /56) can only be read in the router's interface.
- Implication: addresses are published by the rendezvous on every change and are never
  hard-coded. Certificates name hosts, not addresses.

### No earlier floating-IPv6 research exists in the repo
[M] The repo was grepped for `floating`, VRRP, keepalived, anycast, virtual IP, VIP, prefix
delegation, DHCPv6, ULA, SLAAC and `ipv6`, plus a whole-repo phrase search and a `git log --all`
grep. Every hit was unrelated:
- The 17 `floating` files are about floating image tags and versions.
- The 19 `ipv6` files are about rootless podman, WSL and macOS VZ.

The "virtual floating ipv6" recollection is therefore not in the repo. Its substitute is the
per-service DNS name in §4.

Correction to research B §1: it reported "1505-m63i referenced but not filed". [M]
`tillandsias-plan status 1505-m63i` → `obsoleted`. The row is defined in
`plan/index.d/20260929t205532z-1505-sm2j-…-macuahuitl.yaml:542` and obsoleted by the 1506-3xu7
fragment.

### Defect: `is_ipv6_functional` always returns false
- [S] `crates/tillandsias-headless/src/main.rs` `is_ipv6_functional` parses the unbracketed strings
  `"2001:4860:4860::8888:53"` and `"2606:4700:4700::1111:53"` as `SocketAddr`.
- [M] A scratch rustc probe returned `Err(AddrParseError(Socket))`; the bracketed form returns
  `Ok`.
- `main.rs` `auto_detect_and_configure_ipv6_workaround` therefore always calls the `--ipv4-only` injector.
- [M] `/usr/bin/grep -n ipv4-only ~/.config/containers/containers.conf` on yoga (2026-10-03) printed line 3: `pasta_options = ["--ipv4-only"]`.
  Rootless containers have no IPv6 on every Linux host.
- Fixing the brackets alone yields a coin flip on this LAN (the ECMP blackhole above). The
  repair must probe every default router. Packet 1548-mhyk.

### Floating address options

| mechanism | scope | privilege | macOS VZ / WSL2 guest | verdict |
|---|---|---|---|---|
| VRRP / keepalived VIP | one L2 segment | root daemon | NATed, invisible | rejected |
| unsolicited-NA claim of a fixed address | one L2 segment | CAP_NET_ADMIN | NATed | rejected |
| routed sub-prefix to the leader (DHCPv6-PD) | global | router support + forwarding | no | only if the router can; unknown |
| **DNS name updated to the holder (TTL 60)** | global | API token only | works wherever the host has global v6 | **adopted** |

Platform facts:
- [S] `plan/issues/research-macos-vz-dnssec-ipv6-2026-07-07.md:19-22`: the macOS VZ guest gets
  `fd22::` behind NAT.
- [S] `docs/cheatsheets/runtime/wsl/networking-modes.md:67-70`: WSL2 in NAT mode has no IPv6.
- [S] `plan/issues/optimization/wslconfig-mirrored-resolves-endpoint-ambiguity-2026-08-17.md:5-15`:
  mirrored mode was reverted by operator decision.

Guests can therefore be clients, but not service holders, until a host-side forward exists.

### Inbound reachability over the WAN (not measured; a later rung, ruling 12)
- **v1 path order:** same host → LAN direct → off-LAN over Mesh.
- **Direct IPv6 WAN is deferred to goal packet 1548-v453.**
  - Its candidate order is a router pinhole or PCP/UPnP-IGD v6, then UDP simultaneous open
    coordinated over the rendezvous.
  - Its measurement needs a prober off the /64, because a LAN probe never crosses the router's
    firewall. The instrument and its premise guard (`inbound=unmeasured reason=same-prefix`)
    are specified in that packet.
- **On the LAN, the Pi's bad router advertisement still matters.** LAN hosts reach each other
  over their global /64 addresses without a router. Their outbound IPv6 (GitHub, Cloudflare)
  still takes the Pi's black hole about half the time until 1548-i07i is done.

## 3. Trust (research C, adjusted by ruling 8)

### Existing pieces this reuses
- [S] Orders 563/564/595-6y8b, quoted above.
- [S] The signed SSH-CA design (order 322), D1–D10:
  `plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md:62,77,91,187,204,217,757-790`.
- [S] The per-host Vault mounts `ssh-client-signer` and `ssh-host-signer`:
  `crates/tillandsias-headless/src/vault_bootstrap.rs` `SSH_CLIENT_SIGNER_MOUNT`, `SSH_HOST_SIGNER_MOUNT`.
- [S] Packet 1506-32k5, a per-host X25519 identity pinned in `plan/fleet/peers/`:
  `openspec/changes/fleet-messaging-poc/design.md:125-140`.
- [M] `ls plan/fleet` → "No such file". The directory does not exist yet.

### Adopted: per-host CAs, pinned by the tree, scoped to their own names
- **No fleet-wide signing key exists anywhere.**
- Each host's peer record publishes the public halves of its own Vault CAs.
- Peers trust a host's host-CA only for that host's names, via `@cert-authority <names>`
  [S] https://man.openbsd.org/sshd.8.
- Peers trust a host's user-CA only for the principals the tree grants it, via
  `AuthorizedPrincipalsCommand … %F` [S] https://man.openbsd.org/sshd_config.
- A compromised host vouches only for itself.
- Why the alternatives were rejected:
  - A CA key on the leader would have to move on every handover, and Vault's ssh engine cannot
    export it (D2).
  - An offline root with intermediates is impossible in OpenSSH, which has no certificate
    chaining.
  - Cloudflare Access SSH certificates would make every login depend on Cloudflare, which ruling
    2 forbids.
- **This amends SSH-CA design §3 item 2, "The same CA, different roles" (`ssh-ca…:774-776`).**
  Within a host the item still holds. Across hosts the CA set is federated. The amendment needs
  the operator's signature, collected in 1548-ym32.

### Separate keys per purpose, bound by one peer record
- The SSH CA keys never leave Vault (D2), while the Noise static (1506-32k5) must exist raw in
  daemon memory. The two cannot be one key.
- Rendezvous announcements and lease claims are signed with a dedicated Ed25519
  **announce key**, kept in the host's Vault KV and published in the peer record.
- [I] Research C proposed reusing the SSH host key through SSHSIG. A raw Ed25519 key is chosen
  instead because the Worker verifies with WebCrypto Ed25519 over canonical bytes, and SSHSIG
  framing would have to be re-implemented in the Worker.

### Admission (rulings 8 and 14)
- `tillandsias fleet enroll` requires two stored bundles, both from logins the operator runs on
  that host:
  - a GitHub bundle from `--github-login` (device flow under the operator's 2FA);
  - a Cloudflare bundle from `--cloudflare-login` (1505-kc5f, landed in `7985e2469`).
- Both identities must match the owner pins in `plan/fleet/owner.yaml`: the numeric GitHub user
  id, and a salted hash of the Cloudflare user id. No account id or email is ever written to a
  name (ruling recorded in the 1505-sm2j design note).
- The host's peer record then lands through the normal work-ref flow.
- **Peers trust a host when they fetch its landed record, not when they see its announcement.**
  Discovery is not trust, as order 564 requires.
- **The logins gate enrollment only.** At connection time trust is the CA pinned in the record.
  No host-to-host connection ever checks a live login or token, so a lapsed GitHub or Cloudflare
  token breaks neither SSH nor the experts.
- `tillandsias fleet leave` (and logout) removes the record through a work ref. Removal is the
  revocation.
- Accepted trade-off: control of both of the operator's accounts can admit a host. After
  admission, SSH between hosts needs nothing from Cloudflare.

### SSH defaults

| Item | Default |
|---|---|
| Host certificate | 7 days, renewed at 3 days left |
| User certificate | 16 hours, principal `til:fleet-operator:<login>` |
| sshd | rootless user-mode sshd on a high port; the system sshd only with operator consent |

- [M] On yoga, `systemctl is-enabled sshd` → `disabled`.
- [M] `/usr/lib/firewalld/zones/FedoraWorkstation.xml` opens TCP/UDP 1025–65535.
  `FedoraServer.xml` does not, so a Pi on a Fedora Server image needs one consented
  `firewall-cmd` step.
- Revocation: short certificate lifetimes first, then a KRL rendered from
  `plan/fleet/revoked.yaml` and from removed peer records. A revoke notice relayed through the
  rendezvous only suspends a host until the tree confirms it (the default; ruled in 1548-ym32).

## 4. Elected services and the lease (rulings 3–7)

### Per-service leases in one Durable Object
- Each service (`git-mirror`, `local-experts`, `status`) has a lease row:
  `{service, holder, epoch, expires_at, since}`.
- Hosts heartbeat every **900 s** (15 min) with one signed POST. That POST announces the host,
  renews the leases it holds and returns the roster.
- **Lease TTL 3,600 s.**
- A new holder bumps `epoch` (a monotone fencing number).
- The DO arms a single alarm for the nearest expiry. It never uses timers.

### Eligibility, score and affinity
- **Presence:** a host is eligible for a service only after **4 h of continuous presence**,
  meaning 16 heartbeats with no gap longer than 2 × 900 s.
- **Uptime is measured by the DO** from heartbeat arrivals and never self-reported (order 564).
  - `availability_7d` is the fraction of the 672 fifteen-minute slots in the last 7 days that
    hold a presence.
  - Class is always-on at ≥ 0.95, semi at ≥ 0.60, transient otherwise.
  - The effective class is the minimum of the class declared in the peer record and the class
    measured from availability.
  - A class above transient needs at least 24 h of observation.
- **Score**, compared in order:
  1. Effective class.
  2. Reachability: peers that completed an authenticated connection in the last 24 h,
     bucketed.
  3. Substrate: bare metal over guest.
  4. RAM bucket, log2 of GiB.
  5. Disk-free bucket.
  6. OS.
  7. Host id.
- **Affinity:** operator-authored `plan/fleet/services.yaml`. It lists per service the
  `preferred` hosts, the `eligible` set and `min_presence`. The first entries name macuahuitl
  as preferred for `git-mirror` and `local-experts`. Metrics-driven rules later replace the
  static list without changing the protocol.
- **Preemption:**
  - Only a preferred host, or a host of strictly higher class, that meets `min_presence` may set
    `handoff_requested`. The incumbent yields at its next renew; otherwise the lease expires.
  - Lower-scored hosts take a lease only when it is vacant.
  - A waking laptop therefore never displaces macuahuitl or a Pi.

### What is fenced and what is duplicable
- **Fenced, and the DO does these itself, so they are fenced by construction:**
  - The per-service DNS names.
  - The status page publication.
- **Duplicable, so two holders are harmless:**
  - The git mirror. Every write passes through to GitHub atomically before it is acknowledged;
    see below.
  - Local experts, which answer read-only.
- Signing certificates is not a leader duty (§3).

### Failover bound and quota
- Worst-case failover is lease expiry (≤ 3,600 s) plus the successor's next heartbeat (≤ 900 s),
  so **≤ 75 min**. The operator accepted hour-scale leases.
- [I] Computed from the quotas in §1, for 10 hosts:
  - 96 heartbeats per host per day gives 960 Worker requests and 960 DO requests a day.
  - Rows written are about 2 per heartbeat plus lease renewals plus one `setAlarm` per expiry
    change, so about 2,200 a day. That is 2.2% of 100,000.
  - Each status-page view adds one Worker request and one DO request; the HTML itself is free.
  - Quota stops being a design constraint. A host that receives 1027 or 429 keeps its last
    signed roster and backs off until 00:00 UTC.

### DNS names and choosing the path
- `<host>.fleet.tlatoani.net` (AAAA, DNS-only, TTL 60) points at the host's own global address,
  which is the LAN path. It is written on change only.
- `<host>.mesh.fleet.tlatoani.net` (A) points at the host's Mesh IP, reported in its heartbeat
  once 1506-t97c has joined it.
- `<service>.fleet.tlatoani.net` and `<service>.mesh.fleet.tlatoani.net` are CNAMEs to the
  holder's two names. They are the "floating address".
- Path choice is the client's, never DNS's. `tillandsias fleet resolve <service>` prints the LAN
  address when this host shares the holder's /64 and a 2 s connect succeeds. Otherwise it prints
  the Mesh address. The ssh and git configs call it through `ProxyCommand`.
- Publishing a `100.96.0.0/12` address in public DNS reveals only a private-range address.
  [I] That is acceptable; the alternative, Mesh hostname routes, needs Gateway resolution on
  every client.
- `rendezvous.tlatoani.net` and `status.tlatoani.net` are Worker Custom Domains.
- The failsafe is `tillandsias-rendezvous.<account-subdomain>.workers.dev`.
- SSH to a service name sets `HostKeyAlias <holder>.fleet.tlatoani.net`, so the certificate is
  checked against the real holder's CA. A floating name is never certified.

### Shared git mirror (ruling 7)
- **The mechanism already exists.** [S] `openspec/specs/git-mirror-service/spec.md:171-200`,
  the pre-receive relay: the mirror acknowledges a push only after one `git push --atomic` of
  exactly the received refs is accepted upstream.
- **On macuahuitl:** its mirror becomes reachable to fleet hosts over the fleet sshd, on the LAN
  directly and over Mesh for off-LAN hosts. A forced command limits it to `git-upload-pack` and
  `git-receive-pack` on mirror paths, and only for principals the tree grants. Its relay pushes
  to GitHub with the shared Tillandsias GitHub App credential (ruling 11). GitHub stays the
  source of truth.
- **Attribution: is the committer identity really per host?** [M]
  `git log origin/linux-next -400 --format='%an <%ae> | %cn <%ce>' | sort | uniq -c` returned:

  | identity | commits |
  |---|---|
  | `tlatoani@macuahuitl.ayahuitlcalpan.com` | 295 |
  | `lenovinha@lenovinha.ayahuitlcalpan.com` | 63 |
  | `Tlatoani <bulloncito@gmail.com>` | 27 |
  | `tlatoani@yoga.ayahuitlcalpan.com` | 13 |
  | `land-queue@localhost` | 2 |

  - 371 of 400 commits carry a host-qualified identity. 29 do not: the shared gmail identity and
    the land queue.
  - The ruling's condition ("unless the per-host identity is not already per-host") is met for
    those 29.
  - The design therefore adds no commit trailer and rewrites no commit. Instead, the fleet mirror
    appends the pushing host's SSH certificate principal to its existing accountability log
    (`git-mirror-service` "Git accountability window") for every ref it relays.
  - This needs no change to anyone's commits. The coordinator may still rule a trailer.
- **On every other host:** the local mirror is unchanged for forges.
  - Its upstream becomes `git-mirror.fleet.tlatoani.net` when that holder answers.
  - Otherwise it falls back to GitHub directly, as it always has.
  - The fallback is loud: a status line `fallback:git-mirror:<reason>`.
  - Reads (reconcile fetch) prefer the fleet mirror, which holds every host's pushed refs.
- **Durability is unchanged:** the forge push is acknowledged only after GitHub accepts, whether
  the path runs through one mirror or two.
- **Why this feeds the experts:** macuahuitl's mirror now holds the refs pushed by every host,
  so the local experts there can index the whole fleet's work.

## 5. Open item: Cloudflare setup on the operator's side (the only one left)

Every design question is closed by rulings 11–14. What remains is account setup that only the
operator can do. This is the App checklist from
`plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md` ("What the public Cloudflare App
needs"), updated so the relay is hosted on `tlatoani.net`:

1. **Create the OAuth client.** Dashboard → account → Manage Account → OAuth clients → Create
   client. This needs Super Administrator, Administrator or "OAuth Client Write".
2. **Client settings:**
   - Name `Tillandsias`.
   - Response type `code`.
   - Grant types `authorization_code` and `refresh_token`.
   - Token endpoint auth method `None` (PKCE S256). No client secret exists.
   - Client URL `https://tlatoani.net`. Keep the client PRIVATE: going public is permanent and
     needs DNS TXT domain verification, `cloudflare_oauth_client_publisher=<code>` on
     `tlatoani.net`.
3. **Redirect URLs.** Matching is exact, so every entry is its own line:
   - `http://127.0.0.1:48631/tillandsias/cloudflare/callback`
   - `http://127.0.0.1:48632/tillandsias/cloudflare/callback`
   - `http://127.0.0.1:48633/tillandsias/cloudflare/callback`
   - **`https://rendezvous.tlatoani.net/tillandsias/cloudflare/callback`**, the relay page,
     served as a static asset of the rendezvous Worker (1548-6auk).
   - Optionally the failsafe
     `https://tillandsias-rendezvous.<account-subdomain>.workers.dev/tillandsias/cloudflare/callback`.

   Whether loopback URLs are accepted is still SECONDARY-sourced and must be confirmed on this
   form.
4. **Scopes.** Pick them from the dashboard catalogue; the scope ids are unverified. Needed:
   - User Details Read.
   - Account Settings Read.
   - Access: Service Tokens Write, for the Mesh enrollment of 1505-6w7d.
   - Cloudflare One Networks Write.
   - Zero Trust Gateway Write.
   - Devices Read.
   - WARP Connector / Mesh Write.
   - **Workers Scripts Write and Zone DNS Edit (`tlatoani.net`)**, used only by
     `tillandsias fleet deploy-rendezvous` on the operator's first host.

   Mark everything except User Details Read as optional.
5. **Zero Trust organization on the Free plan.**
   - Team name `tillandsias-enclave-vpn-<github_login>`.
   - Gateway proxy TCP and UDP on.
   - Default device profile on MASQUE.
   - Split Tunnels include `100.96.0.0/12`.
   - **Mesh enabled.** This is back on the critical path for off-LAN hosts (ruling 12).
6. **Workers.**
   - Choose the account `workers.dev` subdomain (the failsafe name).
   - Create a zone-scoped API token, `Zone > DNS > Edit` on `tlatoani.net` only, and store it as
     the Worker secret `CF_DNS_TOKEN` (`wrangler secret put`). No host ever holds it.
7. **Hand the implementers:**
   - the `client_id` (public, embeddable like `GITHUB_APP_CLIENT_ID`; today `CLOUDFLARE_APP_CLIENT_ID`
     is a placeholder, [S] `crates/tillandsias-headless/src/cloudflare_oauth.rs` `CLOUDFLARE_APP_CLIENT_ID`);
   - the registered redirect URLs exactly as entered;
   - the team name;
   - the chosen `workers.dev` subdomain.

### 5a. Review item added by the coordinator at landing (not a blocker)

Per-host public DNS. As drafted, the DO publishes `<host>.fleet.tlatoani.net` AAAA (the host's
observed global address) and `<host>.mesh.fleet.tlatoani.net` A in PUBLIC DNS. For an off-LAN
laptop that discloses its current network (and so its approximate location) to anyone who
queries the name, and it lets anyone enumerate the fleet's home addresses. `fleet resolve` reads
the signed roster, and ssh/git use it as a `ProxyCommand`, so nothing on the data path requires a
public per-host record.

Recommended default (operator to confirm or overrule): publish only `<service>` names publicly,
and keep per-host addresses in the signed roster only. Until the operator rules, 1548-pg32 must
not write per-host records for hosts whose `class_declared` is transient. Service records follow
the holder, which by affinity is macuahuitl, already reachable as the home file server's network.

## 6. Bookkeeping findings filed with this note

- **1548-8ii6.**
  - 1505-svve, 1505-kyx8, 1505-iysn and 1505-kc5f still fold as `ready`. Their code landed as
    `7985e2469`; [M] `git merge-base --is-ancestor 7985e2469 origin/linux-next` → rc 0.
  - The landing note (`plan/index.d/20260930t004826z-31eebbb9-macuahuitl.yaml:17`) says "The row
    author closes from the ledger".
  - `openspec/changes/cloudflare-login-and-fleet-vpn/tasks.md` §5.1 records the tray signal as
    not done, so 1505-kc5f is not cleanly complete.
  - Not closed here: completion needs each closure script run on trunk, which this design session
    did not do.
- **1548-twha.** `plan_answer "status of every packet under milestone 1505-sm2j and 1506-3xu7"`
  refused with three violations: "cited span does not substantiate authority status=obsoleted".
  - The cited spans (`…1505-sm2j…yaml:435-489`, `:491-540`, `:542-589`) are the rows' original
    definitions, each reading `status: ready`.
  - The `obsoleted` status comes from the later 1506-3xu7 fragment.
  - The checker is right; the composer cites the definition instead of the fragment that set the
    status.

## Provenance

- The three research reports were written in this session's scratchpad and are distilled here,
  because the scratchpad does not persist:
  - A: Cloudflare rendezvous (Fable).
  - B: IPv6 and the floating address (Opus).
  - C: trust and leader election (Opus).
- No Cloudflare API was called with credentials.
- No host, router or Pi configuration was changed.
- Repository facts were read at linux-next `08b8862e4`.
