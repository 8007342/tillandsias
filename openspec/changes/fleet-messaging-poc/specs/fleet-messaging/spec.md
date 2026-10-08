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

### Requirement: send validates the shape, refuses secret-shaped bodies, and returns a stable receipt id at once

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
`outbox/new/`, and `send` SHALL print `ok:msg:queued:<id>` immediately,
where `<id>` (`m-<utc>-<8 hex>`, or the caller's `--id`) is the stable
receipt id every later `msg status`, log line and `--in-reply-to` refers
to; a repeated `--id` SHALL print `skip:msg:duplicate:<id>` and write
nothing.

#### Scenario: a token in the body never leaves the lane

- **WHEN** `msg send --to yoga/host --kind FYI` reads a body containing `ghp_` followed by 36 characters
- **THEN** stderr is `refused:msg:secret-shaped:github-token` and `outbox/` is unchanged

#### Scenario: an over-budget body is refused, not truncated

- **WHEN** the body is 9 lines
- **THEN** stderr is `refused:msg:shape:lines>8` and `outbox/` is unchanged

#### Scenario: send returns before any delivery

- **WHEN** `msg send` is run while no daemon is running
- **THEN** it prints `ok:msg:queued:<id>` within 1 s and `msg status <id>` prints `pending`

### Requirement: the ack is produced by the infrastructure when the destination mailbox durably accepts the message, and by nothing else

OPERATOR RULING 2026-09-29: "An agent does 'send this to agent X' and near
immediately gets an ACK meaning the message was delivered, not read. And
that's it." The ack SHALL be produced only by the exchange layer — the
resident `tillandsias --msg-serve` acting as mover on one host or as the
receiving mailbox daemon across hosts — after the message is written into
the destination lane's `inbox/new` and the file and directory are fsync'd
(or the platform equivalent). No agent, harness, inference layer or CLI
verb SHALL write, forge or forward an ack, and there SHALL be no `ack`
verb. On the ack the sender's `receipts/<id>` SHALL record
`acked:<host>/<lane>@<ts>` with the rung, and `msg status <id>` SHALL print
exactly `pending`, `acked:<host>/<lane>@<ts>` (followed by `via:<rung>`) or
`undelivered:<reason>`. Delivery SHALL be at least once: the sender's
daemon retries with backoff from 1 s doubling to 60 s until the TTL, and a
mailbox SHALL absorb a message whose `(from, id)` is already in its `seen`
set while acking it again. `msg recv` SHALL print every message in
`inbox/new` and `inbox/cur` ordered by `(from, seq)`, moving `new` to
`cur` as local read bookkeeping that is never reported to the sender and
never gates delivery; `--keep` SHALL print without moving. A `seq` gap
SHALL be delivered and flagged `gap:`; no ordering across different
senders is promised.

#### Scenario: the ack is the mailbox's, not the reader's

- **WHEN** a message is delivered into a lane whose agent never runs `msg recv`
- **THEN** the sender's `msg status <id>` prints `acked:<host>/<lane>@<ts>` as soon as the mailbox has fsync'd it

#### Scenario: reading changes nothing on the sender's side

- **WHEN** the recipient runs `msg recv` twice
- **THEN** both calls print the message and the sender's `receipts/<id>` is byte-identical before and after

#### Scenario: a duplicate is absorbed

- **WHEN** the same envelope arrives twice at a mailbox
- **THEN** `inbox/new` holds one file and both arrivals were acked

#### Scenario: no verb can ack

- **WHEN** `tillandsias-plan msg ack <id>` is run
- **THEN** it is refused as an unknown verb and no receipt file changes

### Requirement: every message carries a bounded TTL; the queue is ephemeral

Every envelope SHALL carry `ttl_s`, defaulting to 86,400 (24 h) and
settable per send with `--ttl <s>` within 60 ≤ `ttl_s` ≤ 604,800 (7 d); a
value outside the bounds SHALL be refused with
`refused:msg:ttl-out-of-bounds:<value>:min=60:max=604800`. A message whose
TTL expires before any ack SHALL move to the sender's `dead/` and
`msg status <id>` SHALL print `undelivered:expired`; a message the
destination mailbox positively refuses SHALL print
`undelivered:refused:<verdict>`. A message in a mailbox, read or unread,
SHALL be dropped from that mailbox at its TTL (swept by the daemon and on
every `recv`), and `recv` SHALL never print an expired message. Receipts
SHALL be kept 604,800 s after their terminal state and then dropped, after
which `msg status <id>` prints `unknown:receipt-expired`. There SHALL be no
other retention rule.

#### Scenario: the default TTL is a day

- **WHEN** `msg send` is run without `--ttl`
- **THEN** the queued envelope's `ttl_s` is 86400

#### Scenario: an out-of-bounds TTL is refused

- **WHEN** `msg send --ttl 30` or `msg send --ttl 700000` is run
- **THEN** stderr is `refused:msg:ttl-out-of-bounds:<value>:min=60:max=604800` and nothing is written

#### Scenario: expiry before ack is undelivered:expired

- **WHEN** a message with `--ttl 60` is sent to a host with no reachable daemon
- **THEN** within 65 s it is in `dead/` and `msg status <id>` prints `undelivered:expired`

#### Scenario: an unread message leaves the mailbox at its TTL

- **WHEN** a message with `--ttl 60` was acked into a lane and 61 s pass with no `recv`
- **THEN** `msg recv` prints nothing and `inbox/` holds no file for that id, while the sender's `msg status <id>` still prints `acked:`

### Requirement: a broadcast is one send with many independent acks, and is never replied to

`msg send` SHALL accept several `--to` addresses and group names:
`@all-hosts` (the `host` lane of every host listed in
`plan/fleet/peers/`), `@<host>/*` (every lane directory present on that
host at delivery time), and any name defined in `plan/fleet/groups.yaml`
(a committed map from `@<name>` to a list of addresses or other groups).
A send with more than one resolved recipient SHALL be a broadcast: one
receipt id, `broadcast: true` on every recipient's copy, and one
independent ack per destination mailbox; `msg status <id>` SHALL print
`broadcast:<n>` then one line per recipient reading `acked:<mailbox>@<ts>`,
`pending:<mailbox>` or `undelivered:<reason>:<mailbox>`. A send whose
`--in-reply-to` names a broadcast id SHALL be refused by the CLI with
`refused:msg:reply-to-broadcast:<id>:a broadcast has no single
counterpart; send a new message to <from address> instead`, and the
exchange layer SHALL refuse the same envelope again if it reaches a mailbox
(the sender then reads `undelivered:refused:reply-to-broadcast`). An
`--in-reply-to` naming an id unknown to the local mailbox and receipts
SHALL be refused with `refused:msg:unknown-reply-target:<id>`.

#### Scenario: each recipient acks on its own

- **WHEN** `msg send --to a/host --to b/host` is run and only `a` is reachable
- **THEN** `msg status <id>` prints `broadcast:2`, `acked:a/host@<ts>` and, after the TTL, `undelivered:expired:b/host`

#### Scenario: a reply to a broadcast is refused at the CLI

- **WHEN** a recipient of a broadcast runs `msg send --in-reply-to <that id>`
- **THEN** stderr is `refused:msg:reply-to-broadcast:<id>:a broadcast has no single counterpart; send a new message to <from address> instead` and nothing is written

#### Scenario: a reply to a broadcast is refused by the exchange layer too

- **WHEN** an envelope with `in_reply_to` naming a broadcast id is written straight into an outbox directory, bypassing the CLI
- **THEN** the mover moves it to `dead/` and the sender's `msg status` prints `undelivered:refused:reply-to-broadcast`

#### Scenario: a group is resolved from the tree

- **WHEN** `plan/fleet/groups.yaml` defines `@builders` as `[macuahuitl/host, lenovinha/host]` and `msg send --to @builders` is run
- **THEN** `msg status <id>` prints `broadcast:2` with one line per member

### Requirement: on one host the mover attributes a sender by its mounted lane

`--msg-serve` SHALL treat the directory a message sits in as the sender's
lane: an envelope whose `from.lane` differs SHALL be moved to `dead/` with
`refused:msg:from-lane-mismatch` logged and nothing delivered. The mover
SHALL run the secret check a second time on every message it moves, so a
lane writing its outbox directory directly cannot bypass it. On a local
delivery the mover SHALL fsync the inbox file and directory before writing
the `acked:<host>/<lane>@<ts>` receipt. Each forge SHALL receive its own
lane directory bind-mounted read-write at `/run/host/tillandsias-msg` and
only that directory, with `TILLANDSIAS_MSG_LANE` exported; the directory
SHALL live on the host under `$XDG_STATE_HOME/tillandsias/msg/lanes/<lane>/`
so it survives the container.

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
`noise_pub`, `noise_fp` and optional `lan_hints` and `mesh_ip`. Two daemons SHALL
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
- **THEN** the receiver logs `refused:msg:unknown-peer:<fp>`, no file appears in any inbox, and the sender's `msg status` stays `pending`

#### Scenario: a spoofed mDNS answer cannot add a peer

- **WHEN** an mDNS answer advertises `host=macuahuitl` with a fingerprint not in the directory
- **THEN** the daemon ignores the hint, increments `mdns_ignored`, and resolves macuahuitl from the directory or `mesh_ip` only

#### Scenario: a captured envelope replayed in a new session is dropped

- **WHEN** an envelope already in a receiver's `seen` set arrives again over a fresh session
- **THEN** the receiver acks, writes nothing, and `inbox/new` is unchanged

### Requirement: the transport ladder is tried in order and the rung is recorded

For a remote destination the daemon SHALL resolve the peer from
`lan_hints`, then mDNS, then `mesh_ip`, in that order, and SHALL record the
rung that carried the ack in the receipt so `msg status` prints
`via:local`, `via:lan` or `via:mesh`. The Mesh rung SHALL be served by the
router sidecar binding `<mesh_ip>:<port>` in the router's network
namespace and piping bytes to the host daemon; it SHALL NOT bind the
enclave bridge address and SHALL carry only ciphertext.

#### Scenario: status names the rung

- **WHEN** a message to a LAN peer is acked
- **THEN** `msg status <id>` prints `acked:<host>/<lane>@<ts>` then `via:lan`

### Requirement: the ledger stays the record and only the infrastructure writes to it about delivery

When a message that named a row with `--row` reaches `undelivered:expired`,
the sending daemon — never an agent — SHALL append an `undelivered` event
to that row naming the id, the destination mailbox and the TTL; no other
message outcome SHALL write to the ledger. `plan/inbox/codex.md` SHALL be
reduced to a pointer to `msg recv`, and `plan_only_peers` SHALL name
`tillandsias-plan msg recv` as its first step, with the ledger steps
unchanged.

#### Scenario: an expiry is on the row

- **WHEN** a message sent with `--row 1375-amye` expires unacked
- **THEN** the row carries an `undelivered` event naming the id, `<host>/<lane>` and the TTL, whose `agent_id` is the daemon's

#### Scenario: an ack is not a ledger event

- **WHEN** a message sent with `--row 1375-amye` is acked by the mailbox
- **THEN** the row gains no event
