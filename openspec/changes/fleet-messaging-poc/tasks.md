# Tasks — fleet-messaging-poc

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the fixture named in its packet's `verifiable_closure`.

## 1. Store, shape and CLI [1506-nvqt, opus]

- [ ] 1.1 `msg_shape` (pure): the 600-byte/8-line budget with the KIND
      vocabulary and the ref rule; `secret_shaped` with the pattern list
      from the design note.
- [ ] 1.2 `msg_store`: lane directories, `tmp` → `rename` writes, `seq`,
      `seen`, receipts; envelope YAML on disk.
- [ ] 1.3 `tillandsias-plan msg whoami|send|recv|ack|list|status|lint|gc`
      and the `capabilities` entry.
- [ ] 1.4 `scripts/test-fleet-msg-store.sh`: shape refusals, secret
      refusals, duplicate id, `recv` twice before `ack`, `status`
      transitions, gap flag.

## 2. Same-host mover and lane mounts [1506-q7ab, opus]

- [ ] 2.1 `tillandsias --msg-serve`: watch outboxes, verify `from.lane`
      by directory, second `secret_shaped`, hard-link delivery, receipts,
      wake socket, `<host>/*` fan-out.
- [ ] 2.2 Forge launch args: bind-mount the lane directory at
      `/run/host/tillandsias-msg` and export `TILLANDSIAS_MSG_LANE`, beside
      the MCP mount.
- [ ] 2.3 `scripts/test-fleet-msg-same-host.sh`: two lanes on one host,
      a lane that lies about `from.lane`, a body written straight into an
      outbox directory that only the mover can refuse.

## 3. MCP tools and non-Claude entrypoints [1506-ssb5, sonnet]

- [ ] 3.1 `forge-plan.sh`: `msg_send`, `msg_recv`, `msg_ack`, `msg_list`,
      `msg_status` wrapping the verbs with the capability probe.
- [ ] 3.2 `entrypoint-forge-codex.sh` and the OpenCode entrypoint print
      `msg recv` at session start.
- [ ] 3.3 `scripts/test-fleet-msg-mcp.sh`: JSON-RPC round trip; an old
      binary without the verb answers the degraded envelope.

## 4. Host identity and Noise XX [1506-32k5, opus]

- [ ] 4.1 `--msg-serve --mint [--rotate]`: X25519 static into
      `secret/fleet/msg/static`; the forge policy grants nothing there.
- [ ] 4.2 `plan/fleet/peers/<host>.yaml` writer and reader; fingerprint.
- [ ] 4.3 `tillandsias-secure-channel`: `Noise_XX_25519_ChaChaPoly_BLAKE2s`
      constructor on `EncryptedStream`; `proto` first frame.
- [ ] 4.4 `scripts/test-fleet-msg-identity.sh`: known peer completes,
      unknown key refused before any envelope, wrong `proto` major refused.

## 5. LAN rung [1506-7tq4, opus]

- [ ] 5.1 TCP listener on `TILLANDSIAS_MSG_PORT`; resolution order
      directory → mDNS → mesh; `stored` and `acked` receipts; backoff and
      expiry; `from-host-mismatch`; seen-set and window.
- [ ] 5.2 mDNS advertise and browse as hints only.
- [ ] 5.3 `scripts/test-fleet-msg-lan.sh`: two daemons on one host with
      two state roots and ports; replay of a captured envelope; a spoofed
      mDNS hint; expiry into `dead/`.
- [ ] 5.4 Live arm: yoga bare-metal → macuahuitl Codex lane; the `ack`
      event on the named row; recorded in the milestone's events.

## 6. Cloudflare rung research [1506-euvq, sonnet]

- [ ] 6.1 `images/warp/` Containerfile and entrypoint (warp-svc as PID 1).
- [ ] 6.2 `scripts/research-warp-sidecar-rootless.sh`: launch the sidecar
      beside a router, print the regime, end with one of five outcomes.
- [ ] 6.3 Result recorded in the design note §2 and the packet's events.

## 7. Cloudflare rung join [1506-t97c, opus]

- [ ] 7.1 `warp` container profile in `container_spec` with its
      justification; `--fleet-vpn join|leave|status` launches, removes and
      reads the sidecar; `mesh_ip` into Vault and `plan/fleet/peers/`.
- [ ] 7.2 Router sidecar Mesh relay bound to the Mesh IP only.
- [ ] 7.3 Guest-side join on macOS and Windows (same code, guest headless).
- [ ] 7.4 `scripts/test-fleet-vpn-join-sidecar.sh` with a fake `podman`
      and a fake `warp-cli` inside it.

## 8. Ledger integration [1506-b8du, sonnet]

- [ ] 8.1 `msg ack --row` → `ack` event; expiry → `undelivered` event.
- [ ] 8.2 `plan/inbox/codex.md` pointer; `plan_only_peers` step 0.
- [ ] 8.3 `scripts/test-fleet-msg-ledger.sh`.

## 9. Milestone close [1506-3xu7]

- [ ] 9.1 Same-host and LAN fixtures green; the live arm recorded;
      research outcome recorded; delta synced to `openspec/specs/`.
