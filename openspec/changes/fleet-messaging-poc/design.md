# Design — fleet-messaging-poc

Umbrella packet: `1506-3xu7`. Code is cited by SYMBOL; nothing here is a
line number. Research, sources, the threat table and the operator questions:
`plan/issues/fleet-messaging-poc-design-2026-09-29.md`.

## Context

What exists (read before implementing; none of it is re-filed):

- `scripts/agent-identity.sh` (`id`, `node-name`): the session id is
  `<platform>-<workstation>-<backend>-<utc>` and changes per session; the
  host label is stable. The bus uses the label for addressing and the id
  for attribution.
- `mcp-tool-socket` spec: one socket per lane, bind-mounted into that lane
  only; attribution by the socket, never by the payload
  (`start_mcp_socket_server_for_lane(project_name, instance)`; the lane
  label is `<project>-<instance>`, instance defaulting to `default`).
- `tillandsias-control-wire`: `[u32 length][postcard]` framing with
  `MAX_MESSAGE_BYTES` enforced both ways.
- `tillandsias-secure-channel`: `EncryptedStream` over
  `Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s` with a version-bound PSK
  (`channel_psk`). The stream wrapper is reused; the pattern is not (see
  Decision 4).
- `tillandsias-router-sidecar`: a static musl binary inside the router
  container, already subscribed to the tray's control socket.
- `tillandsias-plan`: installed on every host and in every forge; wrapped
  by `images/default/config-overlay/mcp/forge-plan.sh`; its `capabilities`
  output is how the wrapper learns a verb exists.
- `build_router_run_args`: `--cap-drop=ALL`, `--security-opt=no-new-privileges`,
  `--userns=keep-id`, `--read-only`, enclave alias `router`, loopback
  publish. `weakening_hardening_flag` (tillandsias-podman) refuses
  `--privileged`, non-`keep-id` userns, `--cap-add ALL`; `container_spec`
  has no `cap_add` field on purpose (972-6vaj).
- `plan/inbox/codex.md` (`fab17ec02`) and `plan_only_peers` in
  `methodology/multi-host-development.yaml`.
- `distributed-work.yaml` → `sibling_heads_up_protocol.size_budget`: 600
  bytes, 8 lines, KIND vocabulary, refs on every evidence line.

## Decision 1 — the CLI lives in `tillandsias-plan`; the daemon lives in `tillandsias-headless`

`tillandsias-plan msg <verb>` because that binary is the surface every
harness already has: Codex calls it from the shell, Claude and OpenCode get
it through `forge-plan.sh`, and `capabilities` advertises the verb so a
wrapper can refuse honestly on an old binary. A separate binary would need a
new install path, a new MCP wrapper, a new capability probe and a new
entry in every entrypoint. The verbs:

- `msg whoami` — prints `<host>/<lane>` from `TILLANDSIAS_MSG_LANE` and the
  node name; refuses `refused:msg:no-lane` when the launcher did not export
  one (a session outside any launcher passes `--lane host` explicitly).
- `msg send --to <addr|@group> [--to …] --kind <KIND> [--row <order>]
  [--in-reply-to <id>] [--ttl <s>] [--id <id>] < body` — validates the
  shape, the secret check, the TTL bounds and the reply target, resolves
  groups, assigns `id` and `seq`, writes `outbox/tmp/<id>` then renames
  into `outbox/new/`, and prints `ok:msg:queued:<id>` AT ONCE — the id is
  the stable receipt every later `status`, log line and `--in-reply-to`
  refers to; a repeated `--id` prints `skip:msg:duplicate:<id>`.
- `msg recv [--wait <s>] [--keep] [--json]` — lists `inbox/new` and
  `inbox/cur` ordered by `(from, seq)`, moves `new` → `cur` (local read
  bookkeeping, never reported to the sender; `--keep` skips the move),
  drops anything past its TTL, prints each envelope (`gap:` prefixed when
  `seq` skips), and blocks on the wake socket when `--wait` is given.
- `msg list [--box outbox|inbox|dead]`, `msg status <id>` (`pending` |
  `acked:<host>/<lane>@<ts>` then `via:<rung>` | `undelivered:<reason>`;
  for a broadcast `broadcast:<n>` then one line per recipient), `msg lint
  < body` (the shape check alone, for 1437-arjg to wrap), `msg gc` (the
  TTL sweep by hand).

OPERATOR RULINGS 2026-09-29 on semantics: "ACK just means the message was
accepted by the mailbox; agents will read at their own cadence … ACK
doesn't mean read, it means delivered." And: "An agent does 'send this to
agent X' and near immediately gets an ACK meaning the message was
delivered, not read. And that's it." The ack is produced by the exchange
layer only — the mover on one host, the receiving mailbox daemon across
hosts — after fsync; no agent, harness, inference layer or verb ever
writes one, so there is no `ack` verb and no `msg_ack` tool.

The daemon is `tillandsias --msg-serve` in `tillandsias-headless`, started
by the Linux tray beside the control socket and by the guest headless on
macOS/Windows: it owns the lane directories, the wake socket, the TCP
listener and the peer directory. The CLI never opens a network socket.

## Decision 2 — the store is Maildir-shaped on the host filesystem

`$XDG_STATE_HOME/tillandsias/msg/lanes/<lane>/` with `outbox/{tmp,new}`,
`inbox/{new,cur}`, `dead/`, `receipts/`, `seq` (the sender's counter) and
`seen` (the receiver's `(from, id)` set and per-sender high-water). Nothing
in it outlives its TTL (Decision 5a). Every write is `tmp` then `rename`, so a crash leaves no
half-file and two writers cannot collide; ids are unique so a move is
idempotent. The mover (Decision 3) is the only process that writes into an
`inbox/new` other than its own lane's. A forge's lane directory is
bind-mounted read-write at `/run/host/tillandsias-msg` with
`TILLANDSIAS_MSG_LANE=<project>-<instance>` exported, beside the MCP mount;
the directory survives the container.

Envelope (postcard on the wire, YAML on disk so a human can read a mailbox):
`id`, `from`, `to` (one address per copy), `from_agent`, `seq`, `ts`,
`ttl_s`, `broadcast` (true when the send resolved to more than one
recipient), `kind`, `row`, `in_reply_to`, `body`. `msg_shape` (pure module, no I/O) implements the
budget (≤ 600 bytes, ≤ 8 lines, line 1 `<KIND>:<subject>:<clause>`, every
other line `- ` plus a ref: 7+ hex, an order token, `work/<order>` or a
path) and `secret_shaped(&str) -> Option<&'static str>` (the pattern list in
the design note). A refusal prints `refused:msg:shape:<reason>` or
`refused:msg:secret-shaped:<pattern>` and writes nothing. The whole
envelope is capped at 4,096 bytes.

## Decision 3 — the same-host rung is a mover that attributes by mount

`--msg-serve` watches every lane's `outbox/new`. For a local destination it
verifies `from.lane` equals the lane whose directory the file sits in
(overwriting is not done: a mismatch is `refused:msg:from-lane-mismatch` to
`dead/` with a log line — a lane that lies is evidence, not a typo), runs
`secret_shaped` again (a lane can write its outbox directory directly,
bypassing the CLI), hard-links into the destination's `inbox/new`, fsyncs
the file and the directory, writes `receipts/<id>` =
`acked:<host>/<lane>@<ts>` plus `via:local` in the sender's lane, and pokes
the wake socket `$XDG_RUNTIME_DIR/tillandsias/msg.sock` (one byte per
delivery; `recv --wait` reads it). The group `@<host>/*` is resolved here,
to every lane directory present, one receipt per lane; the mover also
refuses an envelope whose `in_reply_to` names a broadcast copy it holds
(Decision 5b) and sweeps every mailbox at TTL (Decision 5a). Bare-metal sessions share the
lane `host` (one uid, one domain — open question 2 in the design note).

## Decision 4 — hosts authenticate with Noise XX pinned to a directory in the tree

Each host mints one X25519 static key with `--msg-serve --mint`, stored at
`secret/fleet/msg/static` in its OWN Vault (the forge policy grants nothing
under `secret/data/fleet/msg/`), and publishes `plan/fleet/peers/<host>.yaml`
(`host`, `noise_pub`, `fp` = BLAKE2s-128 of the public key, `minted`,
optional `lan_hints: [ip:port]`, `mesh_ip:` once joined) by a normal
landing. `tillandsias-secure-channel` gains
`Noise_XX_25519_ChaChaPoly_BLAKE2s` with static keys beside the existing
`NNpsk0` stream (same `EncryptedStream` type, a second constructor). After
the handshake the daemon looks up the remote static in the directory; an
unknown key is `refused:msg:unknown-peer:<fp>` and the connection closes
before any envelope is read. No PSK and no version binding: the first
plaintext-inside-the-tunnel frame carries `proto: 1`; an unknown major is
refused naming it. mDNS (`_tillandsias-msg._tcp`, TXT `host=`, `fp=`) is a
hint that fills the address; a hint whose `fp` is not in the directory is
ignored and counted.

## Decision 5 — the LAN rung is store-and-forward with one receipt: the mailbox's ack

For a remote destination the daemon resolves the peer (directory
`lan_hints`, then mDNS, then `mesh_ip`), opens a session, sends the
envelope, and waits for `ack` — the receiving daemon has renamed it into
the destination lane's `inbox/new`, fsync'd the file and the directory,
and recorded `(from, id)` in `seen`. Only then does the sender's outbox
entry become `receipts/<id>` = `acked:<host>/<lane>@<ts>` with
`via:lan|mesh`. Failure retries with backoff 1 s doubling to 60 s until
`ttl_s`, then `dead/` and `undelivered:expired` — the only failure there
is, apart from a positive refusal by the destination mailbox
(`undelivered:refused:<verdict>`). A broadcast runs this loop once per
recipient.
The receiving daemon refuses `from.host` ≠ the authenticated peer
(`refused:msg:from-host-mismatch`), absorbs a seen id silently while still
answering `ack`, and drops a `seq` more than 1,000 behind the high-water.
Whether and when the destination agent runs `msg recv` is invisible to
the sender by design. `msg status` reads the receipt file, never guesses.

## Decision 5a — the queue is ephemeral: every message carries a bounded TTL

Default `ttl_s` = 86,400 (24 h). Bounds: 60 ≤ `ttl_s` ≤ 604,800 (7 d);
outside them `send` refuses `refused:msg:ttl-out-of-bounds:<v>:min=60:max=604800`.
Why these numbers: the fleet's slowest scheduled reader is a host slot every
two hours and a coordinator full cycle every four (`multi-host-development.yaml`
slot table), Codex sessions are operator-launched roughly daily, and a
laptop host is closed overnight — 24 h covers all of those and is the
longest a heads-up is still about current work. The minimum equals the
retry backoff cap (60 s), so any message survives at least one retry after
a daemon restart; a shorter TTL would be a message that can expire between
two retries and never be tried at all. The maximum is a week because a
message older than that describes work the ledger has already recorded —
the ledger is the durable record, the queue is not — and it bounds every
mailbox and receipt store by construction. Expiry before any ack is
`undelivered:expired` (the sender's `dead/`); a message a mailbox positively
refuses is `undelivered:refused:<verdict>`. In the mailbox a message, read
or unread, is dropped at its TTL by the daemon's sweep and by `recv`
itself, and `recv` never prints an expired one. Receipts live 604,800 s
after their terminal state, then `status` answers `unknown:receipt-expired`.
This replaces the earlier 7-day/30-day retention rule entirely.

## Decision 5b — broadcasts ack per recipient and are never replied to

`--to` may repeat, and may name a group: `@all-hosts` (the `host` lane of
every host in `plan/fleet/peers/`), `@<host>/*` (every lane directory
present on that host at delivery time; the mover resolves it), or any name
in `plan/fleet/groups.yaml` — a committed map from `@<name>` to a list of
addresses or groups, defined in the tree exactly as peers are, so a group
is a landing, not a runtime claim. More than one resolved recipient makes
the send a broadcast: one receipt id, `broadcast: true` on every copy, and
one independent ack per destination mailbox; `status` prints
`broadcast:<n>` and a line per recipient (`acked:<mailbox>@<ts>`,
`pending:<mailbox>`, `undelivered:<reason>:<mailbox>`). Replies: a send
with `--in-reply-to <id>` is checked at the CLI against the local inbox
copy (the recipient side) or the local receipt (the sender side); a
broadcast id is refused `refused:msg:reply-to-broadcast:<id>:a broadcast
has no single counterpart; send a new message to <from address> instead`,
and an id unknown locally is `refused:msg:unknown-reply-target:<id>`. The
exchange layer enforces the same rule a second time — the mover and the
receiving daemon refuse an envelope whose `in_reply_to` names a broadcast
they hold — so a lane writing its outbox directly gets
`undelivered:refused:reply-to-broadcast`. Both sites are tested.

## Decision 6 — the Cloudflare rung is a sidecar in the router's network namespace, measured first

No host OS runs `warp-svc`. `images/warp/` builds a container from the
vendor package (pinned version) whose entrypoint runs `warp-svc` as PID 1
(no systemd). It launches as `tillandsias-warp` with
`--network container:tillandsias-router` (the TUN and its routes appear in
the router's namespace), `--cap-drop=ALL --cap-add=NET_ADMIN`,
`--device /dev/net/tun`, `--sysctl net.ipv4.conf.all.src_valid_mark=1`,
`--userns=keep-id --user 0`, `--read-only` with a named volume at
`/var/lib/cloudflare-warp` where the tray writes `mdm.xml` from
`secret/cloudflare/mesh` (`service_mode` warp, `warp_tunnel_protocol`
masque, `auth_client_id`/`auth_client_secret`, `organization`,
`auto_connect` 1, `onboarding` false). The `warp` profile is added to
`container_spec` with its own justification, not a `cap_add` field
(972-6vaj); `weakening_hardening_flag` already admits a single named
capability. `tillandsias-router-sidecar` gains a relay: bind
`<mesh_ip>:48640` inside the router namespace and pipe bytes to
`host.containers.internal:48640`; it never binds the enclave bridge
address and only ever sees ciphertext. On macOS and Windows the guest's
router runs the same sidecar and the guest headless does the join.

1506-euvq measures first and records exactly one of
`outcome:mesh-ip-acquired | tun-denied-rootless | firewall-refused |
package-refuses-container | registers-no-mesh-ip` with the regime (client
version, podman version, kernel, host); 1506-t97c wires `--fleet-vpn
join|leave|status` to the sidecar and is blocked by that outcome being
`mesh-ip-acquired`. "Free version only": `init` prints the plan it read,
calls no billing route, and refuses `refused:fleet-vpn:paid-feature:<step>`.

## Decision 7 — the ledger stays the record; the inbox file retires

When a message that named a row reaches `undelivered:expired`, the SENDING
DAEMON writes an `undelivered` event on that row (id, mailbox, TTL) — the
only message outcome the ledger records, and written by the infrastructure,
never by an agent; an ack writes nothing, because the mailbox's acceptance
is not a fact about the work.
The hand-appended `ACK:` note the Codex inbox asked for disappears with the
inbox: `plan/inbox/codex.md` becomes a pointer to `msg recv`;
`plan_only_peers` gains step 0 (`tillandsias-plan msg recv` at session
start, at the peer's own cadence) with everything else unchanged; the Codex
and OpenCode forge entrypoints print pending messages at start. The
600-byte budget is the same rule in both places, so 1437-arjg can close by
wrapping `msg lint`.

## Risks

- WARP in a rootless sidecar is unverified: the community reports a
  firewall failure shape; the outcome is measured, and the PoC does not
  depend on it.
- One shared bare-metal mailbox per host hides which session read a
  message; since reading is local bookkeeping that is never reported, the
  only attribution that matters is `from_agent` on what a session SENDS,
  which is the session id the ledger already uses.
- mDNS on by default advertises host names and fingerprints on the LAN
  (public keys only); open question 3 offers directory-only discovery.
- A peer key lives in the tree: rotating it is a landing plus a `--mint
  --rotate`, and a host whose checkout lags refuses the new key until it
  merges — the refusal names the fingerprint so the remedy is obvious.
