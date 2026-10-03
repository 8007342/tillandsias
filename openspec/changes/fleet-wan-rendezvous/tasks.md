# Tasks — fleet-wan-rendezvous

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the fixture named in its packet's `verifiable_closure`.
External prerequisites from other milestones: 1505-iky3 (names),
1505-svve (fake Cloudflare), 1505-kc5f (login), 1505-6w7d (Zero Trust init),
1506-32k5 (Noise identity), 1506-7tq4 (LAN rung), 1506-euvq / 1506-t97c
(Mesh sidecar — the off-LAN rung), 1505-br88 (experts bind plumbing).

## 0. Decision and measurement

- [ ] 0.1 Decision record for orders 563 / 564 / 595-6y8b, operator signature [1548-ym32, opus]
- [ ] 0.2 Fleet endpoint reachability per substrate over LAN and Mesh [1548-h7qh, sonnet]
- [ ] 0.3 Operator: fix the Pi's router advertisement [1548-i07i, operator]
- [ ] 0.4 Operator: Cloudflare setup checklist (design note §5)

## 1. Pure foundations (need nothing from the operator)

- [ ] 1.1 `tillandsias-fleet-core::score` + `plan/fleet/services.yaml` [1548-dylo, sonnet]
- [ ] 1.2 `plan/fleet/peers/` schema + `fleet peers check` [1548-cii8, sonnet]
- [ ] 1.3 `is_ipv6_functional` per-router repair [1548-mhyk, sonnet]

## 2. Rendezvous

- [ ] 2.1 Canonical encoder + lease state machine in the core crate; fake rendezvous [1548-5t00, opus]
- [ ] 2.2 Worker + one SQLite Durable Object adapter; `fleet deploy-rendezvous`, `fleet publish-roster` [1548-5t00]
- [ ] 2.3 DNS by the Durable Object only; `fleet resolve` LAN → Mesh [1548-pg32, sonnet]
- [ ] 2.4 Status page and relay page as static assets [1548-6auk, sonnet]

## 3. Trust

- [ ] 3.1 `fleet enroll` gated on both logins; `fleet leave` [1548-ciq2, opus]
- [ ] 3.2 Rendered SSH trust, rootless fleet sshd, negative matrix [1548-u5wv, opus]
- [ ] 3.3 Revocation by record removal; relayed notices suspend [1548-vpe4, sonnet]

## 4. Services

- [ ] 4.1 Resident heartbeat and election timing under a simulated clock [1548-2ilf, opus]
- [ ] 4.2 Shared git mirror pass-through with loud local fallback [1548-7onc, opus]
- [ ] 4.3 Fleet experts: lease-following, fleet-ref index, certificate auth [1548-q2fr, opus]
- [ ] 4.4 Partition and quota behaviour [1548-1oq2, sonnet]

## 5. Close

- [ ] 5.1 Live arms of the milestone recorded (yoga on LAN and off-LAN, macuahuitl holder)
- [ ] 5.2 Sync `fleet-rendezvous`, `fleet-trust`, `fleet-services` into `openspec/specs/`

Not v1 (goals): direct IPv6 WAN [1548-v453]; the Pi on Fedora 44 aarch64 [1548-y56i].
