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
- `msg send --to <host>/<lane> --kind <KIND> [--row <order>]
  [--in-reply-to <id>] [--ttl <s>] [--id <id>] < body` — validates the
  shape and the secret check, assigns `id` and `seq`, writes
  `outbox/tmp/<id>` then renames into `outbox/new/`, prints
  `ok:msg:queued:<id>`; a repeated `--id` prints `skip:msg:duplicate:<id>`.
- `msg recv [--wait <s>] [--json]` — lists `inbox/new` and `inbox/cur`
  ordered by `(from, seq)`, moves `new` → `cur`, prints each envelope
  (`gap:` prefixed when `seq` skips), and blocks on the wake socket when
  `--wait` is given.
- `msg ack <id>... [--row <order>]` — moves `cur/<id>` → `acked/`, queues
  the `acked` receipt, and with `--row` appends the `ack` event through the
  existing `append-event` path.
- `msg list [--box outbox|inbox|acked|dead]`, `msg status <id>`
  (`queued|delivered:<ts>:via:<rung>|acked:<ts>|expired:<ts>`),
  `msg lint < body` (the shape check alone, for 1437-arjg to wrap),
  `msg gc`.

The daemon is `tillandsias --msg-serve` in `tillandsias-headless`, started
by the Linux tray beside the control socket and by the guest headless on
macOS/Windows: it owns the lane directories, the wake socket, the TCP
listener and the peer directory. The CLI never opens a network socket.

## Decision 2 — the store is Maildir-shaped on the host filesystem

`$XDG_STATE_HOME/tillandsias/msg/lanes/<lane>/` with `outbox/{tmp,new}`,
`inbox/{new,cur}`, `acked/`, `dead/`, `receipts/`, `seq` (the sender's
counter) and `seen` (the receiver's `(from, id)` set and per-sender
high-water). Every write is `tmp` then `rename`, so a crash leaves no
half-file and two writers cannot collide; ids are unique so a move is
idempotent. The mover (Decision 3) is the only process that writes into an
`inbox/new` other than its own lane's. A forge's lane directory is
bind-mounted read-write at `/run/host/tillandsias-msg` with
`TILLANDSIAS_MSG_LANE=<project>-<instance>` exported, beside the MCP mount;
the directory survives the container.

Envelope (postcard on the wire, YAML on disk so a human can read a mailbox):
`id`, `from`, `to`, `from_agent`, `seq`, `ts`, `ttl_s`, `kind`, `row`,
`in_reply_to`, `body`. `msg_shape` (pure module, no I/O) implements the
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
bypassing the CLI), hard-links into the destination's `inbox/new`, writes
`receipts/<id>` = `delivered:<ts>:via:local` in the sender's lane, and pokes
the wake socket `$XDG_RUNTIME_DIR/tillandsias/msg.sock` (one byte per
delivery; `recv --wait` reads it). `<host>/*` fans out to every lane
directory present. Bare-metal sessions share the lane `host` (one uid, one
domain — open question 2 in the design note).

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

## Decision 5 — the LAN rung is store-and-forward with two receipt levels

For a remote destination the daemon resolves the peer (directory
`lan_hints`, then mDNS, then `mesh_ip`), opens a session, sends the
envelope, and waits for `stored` (the receiving daemon has renamed it into
the destination lane's `inbox/new` and recorded `(from, id)` in `seen`).
Only then does the sender's outbox entry become `receipts/<id>` =
`delivered:<ts>:via:lan|mesh`. Failure retries with backoff 1 s doubling to
60 s until `ttl_s`, then `dead/` and `expired:`. The receiving daemon
refuses `from.host` ≠ the authenticated peer (`refused:msg:from-host-mismatch`),
drops a seen id silently while still answering `stored`, and drops a `seq`
more than 1,000 behind the high-water. When the destination agent runs `msg
ack`, the receiving daemon sends an `acked` receipt back over a session to
the origin host; that flips `receipts/<id>` to `acked:<ts>`. `msg status`
reads the receipt file, never guesses.

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

`msg ack --row` writes the `ack` event the Codex inbox asked for by hand;
an expiry writes `undelivered` on the row; `plan/inbox/codex.md` becomes a
pointer to `msg recv`; `plan_only_peers` gains step 0 (`tillandsias-plan msg
recv` at session start, `msg ack` after reading) with everything else
unchanged; the Codex and OpenCode forge entrypoints print pending messages
at start. The 600-byte budget is the same rule in both places, so 1437-arjg
can close by wrapping `msg lint`.

## Risks

- WARP in a rootless sidecar is unverified: the community reports a
  firewall failure shape; the outcome is measured, and the PoC does not
  depend on it.
- One shared bare-metal mailbox per host hides which session read a
  message; `from_agent` on the `ack` event carries the session id, which is
  the attribution the ledger already uses.
- mDNS on by default advertises host names and fingerprints on the LAN
  (public keys only); open question 3 offers directory-only discovery.
- A peer key lives in the tree: rotating it is a landing plus a `--mint
  --rotate`, and a host whose checkout lags refuses the new key until it
  merges — the refusal names the fingerprint so the remedy is obvious.
