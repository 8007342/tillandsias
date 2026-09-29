## ADDED Requirements

### Requirement: an address is a host and a lane, printed by the tool, never composed by hand

A message address SHALL be `<host>/<lane>` where `<host>` is the label
`scripts/agent-identity.sh node-name` prints and `<lane>` is `host` for
bare-metal sessions or `<project>-<instance>` for a forge (the same label
as its MCP socket directory). `tillandsias-plan msg whoami` SHALL print the
caller's address from `TILLANDSIAS_MSG_LANE` exported by the launcher and
SHALL refuse `refused:msg:no-lane` when no lane is exported and none is
given with `--lane`. The session id from `agent-identity.sh id` SHALL ride
in the envelope's `from_agent` for attribution and SHALL NOT be what
authenticates a sender.

#### Scenario: a forge learns its own address

- **WHEN** `msg whoami` runs inside a forge launched with
  `TILLANDSIAS_MSG_LANE=tillandsias-default`
- **THEN** it prints `<host>/tillandsias-default`

#### Scenario: no lane is a refusal, not a guess

- **WHEN** `msg whoami` runs with no `TILLANDSIAS_MSG_LANE` and no `--lane`
- **THEN** stdout is empty and stderr is `refused:msg:no-lane`

### Requirement: send validates the shape and refuses secret-shaped bodies before writing

`msg send` SHALL read the body from stdin or `--body-file`, never argv, and
SHALL refuse with `refused:msg:shape:<reason>` any body over 600 bytes or 8
lines, whose first line is not `<KIND>:<subject>:<clause>` with KIND in
HEADS-UP, ACK, LANDED, BLOCKED, ASK, FYI, or whose further lines do not
start with `- ` and carry a ref; and SHALL refuse with
`refused:msg:secret-shaped:<pattern>` a body matching a secret pattern
(GitHub `ghp_`/`gho_`/`github_pat_`, Vault `hvs.`/`hvb.`, `AKIA`, `sk-`,
`-----BEGIN` … `PRIVATE KEY`, `Bearer `, a three-part `eyJ` token, any
base64 or hex run of 40 or more characters). A refusal SHALL write nothing.
An accepted message SHALL be written to `outbox/tmp/<id>` and renamed into
`outbox/new/`, and `send` SHALL print `ok:msg:queued:<id>`; a repeated
`--id` SHALL print `skip:msg:duplicate:<id>` and write nothing.

#### Scenario: a token in the body never leaves the lane

- **WHEN** `msg send --to yoga/host --kind FYI` reads a body containing `ghp_` followed by 36 characters
- **THEN** stderr is `refused:msg:secret-shaped:github-token` and `outbox/` is unchanged

#### Scenario: an over-budget body is refused, not truncated

- **WHEN** the body is 9 lines
- **THEN** stderr is `refused:msg:shape:lines>8` and `outbox/` is unchanged

### Requirement: delivery is at least once with two receipt levels and idempotent ids

The resident `tillandsias --msg-serve` SHALL keep a message in the sender's
`outbox/` until the destination daemon has renamed it into the destination
lane's `inbox/new` and answered `stored`, retrying with backoff from 1 s
doubling to 60 s until `ttl_s` (default 86,400), after which the message
SHALL move to `dead/` and `msg status <id>` SHALL print `expired:<ts>`. On
`stored` the sender's `receipts/<id>` SHALL read `delivered:<ts>:via:<rung>`.
`msg recv` SHALL print every message in `inbox/new` and `inbox/cur`, ordered
by `(from, seq)`, moving `new` to `cur`, on every call until `msg ack <id>`
moves it to `acked/` and queues an `acked` receipt that flips the sender's
`receipts/<id>` to `acked:<ts>`. A receiver SHALL drop a message whose
`(from, id)` is already in its `seen` set while still answering `stored`.
A `seq` gap SHALL be delivered and flagged `gap:`; no ordering across
different senders is promised.

#### Scenario: a message is presented until acknowledged

- **WHEN** a lane runs `msg recv` twice without `msg ack`
- **THEN** both calls print the same message id
- **AND** after `msg ack <id>` a third `msg recv` prints nothing and the sender's `msg status <id>` prints `acked:` with a timestamp

#### Scenario: a duplicate is absorbed

- **WHEN** the same envelope arrives twice at a receiving daemon
- **THEN** `inbox/new` holds one file and both arrivals were answered `stored`

#### Scenario: an unreachable peer expires into dead

- **WHEN** a message with `--ttl 2` is sent to a host with no reachable daemon
- **THEN** within 5 s it is in `dead/` and `msg status <id>` prints `expired:`

### Requirement: on one host the mover attributes a sender by its mounted lane

`--msg-serve` SHALL treat the directory a message sits in as the sender's
lane: an envelope whose `from.lane` differs SHALL be moved to `dead/` with
`refused:msg:from-lane-mismatch` logged and nothing delivered. The mover
SHALL run the secret check a second time on every message it moves, so a
lane writing its outbox directory directly cannot bypass it. Each forge
SHALL receive its own lane directory bind-mounted read-write at
`/run/host/tillandsias-msg` and only that directory, with
`TILLANDSIAS_MSG_LANE` exported; the directory SHALL live on the host under
`$XDG_STATE_HOME/tillandsias/msg/lanes/<lane>/` so it survives the
container. `<host>/*` SHALL fan out to every lane directory present.

#### Scenario: a lane cannot speak for another

- **WHEN** lane `a-default` writes an envelope with `from` = `<host>/b-default` into its own `outbox/new`
- **THEN** the mover moves it to `dead/`, logs `refused:msg:from-lane-mismatch`, and `b-default`'s inbox is unchanged

#### Scenario: the mover catches what the CLI was bypassed on

- **WHEN** a well-formed envelope whose body contains `hvs.` followed by 24 characters is written directly into `outbox/new`
- **THEN** the mover moves it to `dead/` with `refused:msg:secret-shaped:vault-token` and delivers nothing

### Requirement: peers authenticate with Noise XX pinned to the directory in the tree

Each host SHALL hold one X25519 static key at `secret/fleet/msg/static` in
its own Vault, minted by `--msg-serve --mint`, readable by no forge policy,
and SHALL publish `plan/fleet/peers/<host>.yaml` carrying `host`,
`noise_pub`, `fp` and optional `lan_hints` and `mesh_ip`. Two daemons SHALL
complete `Noise_XX_25519_ChaChaPoly_BLAKE2s` and each SHALL look the
remote static key up in the directory before reading any envelope; an
unknown key SHALL be refused with `refused:msg:unknown-peer:<fp>` and the
connection closed. The daemon SHALL refuse an envelope whose `from.host`
differs from the authenticated peer with `refused:msg:from-host-mismatch`.
The first in-tunnel frame SHALL carry `proto`; an unknown major SHALL be
refused naming it. Keys SHALL NOT be version-bound. mDNS
(`_tillandsias-msg._tcp`) SHALL only supply addresses for hosts already in
the directory.

#### Scenario: an unknown host gets nothing

- **WHEN** a daemon holding a key absent from `plan/fleet/peers/` connects and sends an envelope
- **THEN** the receiver logs `refused:msg:unknown-peer:<fp>`, no file appears in any inbox, and the sender's `msg status` stays `queued`

#### Scenario: a spoofed mDNS answer cannot add a peer

- **WHEN** an mDNS answer advertises `host=macuahuitl` with a fingerprint not in the directory
- **THEN** the daemon ignores the hint, increments `mdns_ignored`, and resolves macuahuitl from the directory or `mesh_ip` only

#### Scenario: a captured envelope replayed in a new session is dropped

- **WHEN** an envelope already in a receiver's `seen` set arrives again over a fresh session
- **THEN** the receiver answers `stored`, writes nothing, and `inbox/new` is unchanged

### Requirement: the transport ladder is tried in order and the rung is recorded

For a remote destination the daemon SHALL resolve the peer from
`lan_hints`, then mDNS, then `mesh_ip`, in that order, and SHALL record the
rung that carried the `stored` receipt in the receipt so `msg status`
prints `via:local`, `via:lan` or `via:mesh`. The Mesh rung SHALL be served
by the router sidecar binding `<mesh_ip>:<port>` in the router's network
namespace and piping bytes to the host daemon; it SHALL NOT bind the
enclave bridge address and SHALL carry only ciphertext.

#### Scenario: status names the rung

- **WHEN** a message to a LAN peer is delivered
- **THEN** `msg status <id>` prints `delivered:<ts>:via:lan`

### Requirement: the ledger stays the record

`msg ack --row <order>` SHALL append an `ack` event to that row carrying the
message id and `from_agent`; an expiry of a message that named a row SHALL
append an `undelivered` event naming the id and the destination.
`plan/inbox/codex.md` SHALL be reduced to a pointer to `msg recv`, and
`plan_only_peers` SHALL name `tillandsias-plan msg recv` as its first step
and `msg ack` after reading, with the ledger steps unchanged.

#### Scenario: an acknowledgement is on the row

- **WHEN** a Codex lane runs `msg ack <id> --row 1375-amye`
- **THEN** `tillandsias-plan status 1375-amye` shows an `ack` event naming `<id>`

#### Scenario: an expiry is on the row

- **WHEN** a message sent with `--row 1375-amye` expires
- **THEN** the row carries an `undelivered` event naming the id and `<host>/<lane>`
