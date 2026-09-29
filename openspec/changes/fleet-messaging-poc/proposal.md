# Proposal — fleet-messaging-poc

Umbrella packet: `1506-3xu7` (milestone, desired_release v0.6, ahead of the
rest of 1505-sm2j). Research and decision record:
`plan/issues/fleet-messaging-poc-design-2026-09-29.md`.

## Why

The operator's direction (2026-09-29): start with a proof of concept of the
free-tier VPN "just for MESSAGE PASSING BETWEEN HARNESSES in the same host,
and in the same network. This is the missing coordination layer our fleet
needs." Discover the local network when available, "handle our own tunnels
when possible", be careful with security, and run Cloudflare's software
inside a container (the router), never on the host OS.

Today coordination is a git push of an append-only ledger plus a
vendor-specific session channel that only Claude sessions have. Codex cannot
receive a message at all: the coordinator writes `plan/inbox/codex.md` and
asks for a hand-appended `ACK:` note. There is no delivery receipt on any
channel, peers have "confirmed" claims that never reached origin, and the
ledger (31,678 lines) cannot serve as a mailbox.

Two facts fix the shape:

1. Cloudflare's Mesh documentation says proxy-only mode is unsupported and
   Mesh needs Traffic and DNS mode — so the client in a container must run
   WARP mode with a TUN device, and 1505-m63i's proxy-mode measurement is
   answered without running it.
2. Every host's Vault is its own; there is no fleet CA. Cross-host trust
   therefore comes from the tree: a host is a peer iff its public key file
   is on the checkout.

## What Changes

- **ADDED** capability `fleet-messaging`: a harness-agnostic message bus —
  `tillandsias-plan msg send|recv|ack|list|status|whoami|lint|gc`, the
  `forge-plan` MCP tools `msg_*`, per-lane Maildir-style mailboxes on the
  host filesystem bind-mounted into forges, a resident `tillandsias
  --msg-serve` that moves messages between lanes on one host and carries
  them to peers over TCP with Noise XX pinned to `plan/fleet/peers/`,
  at-least-once delivery with `delivered` and `acked` receipts, idempotent
  ids, per-sender sequence, the 600-byte/8-line shape budget and a
  secret-shaped body refusal enforced at two sites, and ledger integration
  (`ack` and `undelivered` events on the named row).
- **MODIFIED** (in `cloudflare-login-and-fleet-vpn`, Decision 5 and the
  `fleet-vpn` delta): no host OS runs `warp-svc`. The Cloudflare One Client
  runs in a dedicated `tillandsias-warp` sidecar container that shares the
  router container's network namespace, with exactly `--cap-add NET_ADMIN`
  and `--device /dev/net/tun` on its own profile; the router sidecar relays
  the Mesh-side TCP port to the host daemon; macOS and Windows run the same
  sidecar inside their Linux guest. Packets 1505-bhsb, 1505-g6zc and
  1505-m63i are obsoleted by 1506-t97c and 1506-euvq.
- `plan/inbox/codex.md` becomes a pointer; `plan_only_peers` gains `msg
  recv` as its first step; the ledger remains the record.

## Impact

- Specs: one new capability (`specs/fleet-messaging/spec.md`); the
  `fleet-vpn` delta of the sibling change is amended in place (the change
  is unsynced, so the amendment is an edit of the delta, not a new delta).
- Code (by packet): `crates/tillandsias-plan` (`msg_store`, `msg_shape`,
  the `msg` verb), `crates/tillandsias-headless` (`--msg-serve`, the lane
  mount in forge launch args, `--fleet-vpn join` revised, a `warp`
  container profile), `crates/tillandsias-secure-channel` (a second Noise
  pattern with static keys), `crates/tillandsias-router-sidecar` (Mesh
  relay), `images/default/config-overlay/mcp/forge-plan.sh`,
  `images/default/entrypoint-forge-codex.sh` and the OpenCode entrypoint,
  a new `images/warp/`, `plan/fleet/peers/`, `scripts/test-*.sh`.
- Operator: answers the five open questions in the design note; provides
  the Zero Trust organization and service tokens only for the Cloudflare
  rung, which is outside the PoC gate.
- Out of scope for the PoC: macOS/Windows bare-metal lanes (their forges
  and the daemon live in the guest; host-native sessions join in a later
  packet), fleet-wide broadcast as a feature, store-and-forward through a
  third host, message-level signatures (needed only when relays exist),
  any paid Cloudflare feature.
