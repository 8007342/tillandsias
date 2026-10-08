## ADDED Requirements

### Requirement: availability is measured by the rendezvous and orders the hosts

The rendezvous SHALL compute `availability_7d` from heartbeat arrivals in the
672 fifteen-minute slots of the last 7 days, SHALL derive `class_measured`
(2 at ≥ 0.95, 1 at ≥ 0.60, else 0; 0 until 24 h of observation), and SHALL
use `class_effective = min(class_declared, class_measured)`. Hosts SHALL be
ordered by the tuple (class_effective, reachability bucket, substrate,
floor(log2 RAM GiB), floor(log2 free disk GiB), os, host id). A host SHALL
be eligible for a service only after 4 h of continuous presence (16
heartbeats, no gap over 1800 s) and only while its last egress probe passed.

#### Scenario: a powerful transient laptop never outranks an always-on host

- **WHEN** 10,000 random attribute sets are scored
- **THEN** no host with class_effective 0 outranks a host with class_effective 2

### Requirement: operator affinity decides between eligible hosts and moves leadership slowly

`plan/fleet/services.yaml` SHALL name per service the `preferred` hosts, the
`eligible` set and `min_presence`; its first content SHALL prefer macuahuitl
for `git-mirror` and `local-experts`. A vacant lease SHALL go to the best
eligible present host (preferred first, then score). An occupied lease SHALL
move only when a preferred host, or a host of strictly higher class, that
meets `min_presence` requests hand-off; the holder SHALL release at its next
renew. A lower-ranked host SHALL NOT take an occupied lease.

#### Scenario: a laptop waking up does not take the mirror

- **WHEN** macuahuitl holds `git-mirror` and yoga (class 0) heartbeats for 12 simulated hours
- **THEN** macuahuitl still holds the lease and the epoch is unchanged

#### Scenario: failover is bounded

- **WHEN** the holder stops heartbeating with an eligible successor present
- **THEN** the successor holds the lease within 75 simulated minutes

### Requirement: the client chooses LAN first, Mesh off-LAN, and says which

`tillandsias fleet resolve <host|service>` SHALL print the LAN address when
this host shares the target's /64 and a 2 s connect succeeds, else the
target's Mesh IP when this host has joined Mesh, else
`unreachable:<name>:<reason>`, and SHALL print the rung used
(`via:lan|via:mesh`). Downloads, ISOs and container images SHALL NOT be
routed over Mesh.

#### Scenario: an off-LAN laptop reaches the mirror over Mesh

- **WHEN** yoga is on a foreign network with Mesh joined and asks for `git-mirror`
- **THEN** resolve prints macuahuitl's Mesh IP and `via:mesh`

### Requirement: the shared git mirror is a pass-through with a loud local fallback

The `git-mirror` holder SHALL serve its per-project mirrors over the fleet
sshd to `til:fleet-mirror:<host>` principals only, through a forced command
admitting `git-upload-pack` and `git-receive-pack` on mirror paths, and SHALL
relay pushes with the existing pre-receive relay of `git-mirror-service`
(atomic, acknowledged only after GitHub accepts) using the shared
Tillandsias GitHub App credential, preserving commits unchanged and appending
the pushing host's principal to its accountability log. Every other host's
local mirror SHALL keep serving its forges and SHALL relay to the fleet
mirror when its record is not stale and it answers within 5 s, else to
GitHub directly, printing `fallback:git-mirror:<reason>`.

#### Scenario: an acknowledgement never precedes GitHub

- **WHEN** a forge pushes through its local mirror and the fleet mirror while the fake GitHub delays acceptance
- **THEN** the forge's push returns success only after the fake GitHub holds the new ref

#### Scenario: the fleet mirror is down

- **WHEN** the `git-mirror` holder is unreachable
- **THEN** the forge push succeeds through GitHub directly and the status shows `fallback:git-mirror:unreachable`

### Requirement: fleet experts follow the lease, index fleet refs, and authenticate by certificate

The `local-experts` holder SHALL serve `expert-serve` only to clients
presenting a certificate from a CA pinned in a landed peer record (mutual
TLS, or an SSH-forwarded port with a fleet user certificate); the shared
bearer of 1505-br88 SHALL NOT be accepted. Its index SHALL name the refs and
commits it was built from, covering `linux-next`, `main` and every
`refs/heads/*` relayed through the fleet mirror in the last 14 days. A spoke
SHALL fall back to its own experts with `fallback:local-experts:<reason>`.

#### Scenario: a bearer alone is refused

- **WHEN** a client presents the old bearer without a pinned-CA certificate
- **THEN** the experts endpoint refuses the connection before any retrieval
