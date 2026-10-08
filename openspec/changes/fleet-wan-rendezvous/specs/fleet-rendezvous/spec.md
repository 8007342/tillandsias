## ADDED Requirements

### Requirement: a host speaks to the rendezvous only with a signed heartbeat

A host SHALL send `POST /v1/heartbeat` at most every 900 s carrying its
host, a strictly increasing `seq`, a `ts`, its addresses, its declared
attributes, and the services it renews or requests, signed with Ed25519 over
the canonical bytes produced by `tillandsias-fleet-core`. The rendezvous
SHALL verify the signature against the announce key published for that host
by `tillandsias fleet publish-roster` from the landed peer records, and
SHALL refuse with `401 refused:rendezvous:unknown-host` a key it does not
hold, `refused:rendezvous:stale-ts` a `ts` more than 300 s from its clock,
and `refused:rendezvous:replay` a `seq` not greater than the last accepted
one, storing nothing on any refusal. The response SHALL be the roster,
signed by the rendezvous key whose public half is `plan/fleet/rendezvous.pub`.

#### Scenario: an unknown key is refused and leaves no trace

- **WHEN** a heartbeat signed by a key absent from the published roster arrives
- **THEN** the answer is 401 `refused:rendezvous:unknown-host` and the host table is unchanged

#### Scenario: host and Worker agree on the signed bytes

- **WHEN** 1,000 random heartbeat bodies are encoded natively and by the wasm build of `tillandsias-fleet-core`
- **THEN** every pair of encodings is byte-identical

### Requirement: per-service leases are granted atomically with monotone epochs

The rendezvous SHALL hold one lease per service (`git-mirror`,
`local-experts`, `status`, and any added to `plan/fleet/services.yaml`) with
holder, epoch, `expires_at = renew time + 3600 s`, and SHALL evaluate renew,
acquire and hand-off in one Durable Object event so that at most one live
holder exists per service at any instant and every change of holder
increments the epoch. Lease expiry SHALL be driven by a single Durable Object
alarm; the Worker and Durable Object source SHALL NOT call `setTimeout` or
`setInterval`.

#### Scenario: concurrent acquires never produce two holders

- **WHEN** five contenders race for one vacant service in 1,000 random interleavings against the fake rendezvous
- **THEN** no interleaving shows two live holders and the epoch sequence is strictly increasing

#### Scenario: a timer in the Durable Object source fails the build

- **WHEN** `setInterval` or `setTimeout` appears under `cloud/rendezvous/`
- **THEN** the rendezvous fixture fails naming the file and line

### Requirement: the Durable Object is the only writer of fleet DNS records

Fleet records SHALL be written only by the rendezvous with a zone-scoped
token held as a Worker secret; no host SHALL hold a DNS token. Records SHALL
be DNS-only (`proxied: false`) with TTL 60: `<host>.fleet.tlatoani.net` AAAA
(observed global address), `<host>.mesh.fleet.tlatoani.net` A (reported Mesh
IP), and per service `<service>.fleet.tlatoani.net` /
`<service>.mesh.fleet.tlatoani.net` CNAMEs to the holder's names plus TXT
`epoch=<n> holder=<host>`. Records SHALL be written only on change. On
vacancy the service records SHALL be kept and the TXT SHALL gain
`stale=<ts>`.

#### Scenario: a handover rewrites the service name once

- **WHEN** the `git-mirror` lease moves from host A to host B against the fake DNS API
- **THEN** the call ledger shows exactly one write per service record, all with `proxied:false` and `ttl:60`, and TXT `epoch=<n+1> holder=B`

### Requirement: quota exhaustion degrades to the last roster, never to silence

A host that receives 1027 or 429 from the rendezvous SHALL keep its last
signed roster, SHALL back off until 00:00 UTC on 1027, and SHALL report
`blocked:rendezvous:quota:<code>` in its status; a host that cannot reach
the rendezvous SHALL report `blocked:rendezvous:unreachable:<reason>`. The
status page and the OAuth relay page SHALL be static assets, so viewing them
consumes no Worker quota beyond one roster read.

#### Scenario: a 1027 keeps service resolution working

- **WHEN** the fake rendezvous answers 1027 to every heartbeat
- **THEN** `tillandsias fleet resolve git-mirror` still prints the last known holder's address and status reads `blocked:rendezvous:quota:1027`
