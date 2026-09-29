# Fleet messaging PoC: an acknowledged message bus between harnesses, and WARP inside the router container (milestone 1506-3xu7)

- classification: research + design (amends `cloudflare-login-fleet-vpn-design-2026-09-29.md`)
- filed: 2026-09-29 (linux/macuahuitl, design-lead session, worktree
  `agent-a28b6190bda5c57aa`, branch `work/fleet-messaging-poc-design`)
- status: designed — packets filed under `plan/index.d/`; nothing implemented
- change: `openspec/changes/fleet-messaging-poc/` (new) and
  `openspec/changes/cloudflare-login-and-fleet-vpn/` (amended: Decision 5)
- desired release: v0.6, AHEAD of the rest of 1505-sm2j
- supersedes: 1505-bhsb, 1505-g6zc, 1505-m63i (obsoleted in the same fragment)

## Operator direction (verbatim intent, 2026-09-29)

1. "We'll install Cloudflare's software on the containers, inside the router
   likely, and will always default to the FREE version only."
2. "We'll have to be clever and distinguish LOCAL NETWORK when available and
   handle our own tunnels when possible. All of this fleet is in the local
   network, some even hard-wired to the same switch, so network discovery
   should not be an issue, but we need to be careful with SECURITY."
3. "Let's start with the PROOF OF CONCEPT of using the free-tier VPN; we'll
   use this just for MESSAGE PASSING BETWEEN HARNESSES in the same host, and
   in the same network. This is the missing coordination layer our fleet
   needs."

## Why a bus, in the fleet's own words

Measured pain, all on the ledger:

- Codex cannot receive a message. The coordinator writes to
  `plan/inbox/codex.md` (commit `fab17ec02`) and asks Codex to append
  `ACK: <msg-id>` to a row; "a message without an ACK counts as
  UNDELIVERED, and the coordinator will repeat it". The channel is a git
  push and a human relay.
- `methodology/multi-host-development.yaml` → `plan_only_peers`: some
  harnesses "coordinate ONLY through the shared ./plan ledger"; the ledger is
  "read AFTER work, not before" (`distributed-work.yaml` →
  `sibling_heads_up_protocol`), which is the wrong shape for "I am about to
  change a thing you depend on".
- The vendor channel (SendMessage over Remote Control) exists only for
  Claude sessions, carries no delivery receipt, and the fleet has recorded
  peers "confirming" claims that never reached origin.
- `plan/index.yaml` is 31,678 lines; the append-only ledger cannot be a
  mailbox (CLAUDE.md, bootstrap block).
- The message budget already exists: `distributed-work.yaml` →
  `sibling_heads_up_protocol.size_budget`: at most 600 bytes and 8 lines,
  line 1 `<KIND>:<subject>:<clause>` with KIND in HEADS-UP, ACK, LANDED,
  BLOCKED, ASK, FYI; every further line `- ` plus a ref. Its lint
  (`scripts/check-peer-message-shape.sh`, 1437-arjg) is still blocked. The
  bus enforces that budget at `send`, which makes the lint a wrapper.

## Research answers

### 1. Can the Cloudflare One Client in proxy mode carry Mesh traffic? NO (documented)

The Mesh get-started page states that DNS-only and proxy-only modes are
unsupported and that nodes must run in Traffic and DNS mode; the
client-device guide repeats that "Mesh connectivity requires Traffic and DNS
mode". This answers 1505-m63i's question from the documentation: the
`reaches-mesh` outcome is excluded, so the measurement is not worth a host's
time. 1505-m63i is obsoleted; what remains open is whether WARP mode runs
inside a rootless container (§2), which is 1506-euvq.

- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/guides/connect-client-devices/
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/
  (local proxy mode: SOCKS5/HTTP on `127.0.0.1:40000`, MASQUE only, 10 s
  request timeout — an HTTP egress mode, not a network participant)

### 2. What does the client need inside a container? (official: nothing documented; community: NET_ADMIN + TUN)

Cloudflare's headless Linux tutorial requires "Root or `sudo` access on a
supported Linux device", writes `/var/lib/cloudflare-warp/mdm.xml` and runs
`sudo systemctl restart warp-svc`. It says nothing about containers,
`/dev/net/tun` or capabilities. There is no official container image and no
official support statement; a community feature request for Docker support
exists (secondary; the page refused an unauthenticated fetch).

Community practice (secondary sources, consistent with each other) runs
`warp-svc` as PID 1 in a container with:

- `--cap-add NET_ADMIN` (create and configure the TUN interface and routes),
- `--device /dev/net/tun` (or `mknod /dev/net/tun c 10 200` at start),
- `--sysctl net.ipv4.conf.all.src_valid_mark=1` (policy routing marks;
  `net.*` sysctls are namespaced, so a rootless netns owner may set them),
- some images add `net.ipv6.conf.all.disable_ipv6=0`;
- a known failure shape: "Failed to start firewall" when the client's own
  nftables rules cannot be installed in the container.

Sources (secondary): https://blog.caomingjun.com/run-cloudflare-warp-in-docker/en/ ,
https://github.com/aleskxyz/warp-svc , https://github.com/zhengxiongzhao/warp-svc ,
https://community.cloudflare.com/t/cloudflare-warp-docker-failed-to-start-firewall/489517 ,
https://community.cloudflare.com/t/support-running-the-cloudflare-warp-client-in-docker/510708 (not fetched).

Rootless podman specifics (kernel semantics, not Cloudflare's): `NET_ADMIN`
granted inside a user namespace is full admin over that namespace's own
network namespace (pasta/slirp4netns), which is all a TUN needs; the host
`/dev/net/tun` node is `0666` on Fedora so `--device` passes it without root;
`--userns=keep-id` maps the invoking user to its own uid and container uid 0
to a subordinate uid, so `--user 0` gives an in-namespace root that owns the
capabilities. Whether `warp-svc` accepts that root, whether its firewall
step survives, and whether the package installs without systemd are the
UNVERIFIED items 1506-euvq measures with five named outcomes.

Project constraints the packet must respect (read in the tree):
`build_router_run_args` launches the router with `--cap-drop=ALL`,
`--security-opt=no-new-privileges`, `--userns=keep-id`, `--read-only`, a
loopback-only publish and the enclave network alias `router`;
`container_spec` deliberately has NO `cap_add` field (972-6vaj: "add the
capability to the profile that needs it with its own justification");
`weakening_hardening_flag` in `tillandsias-podman` refuses `--privileged`,
any `--userns` other than `keep-id`, `--cap-add ALL` and weakening
`--security-opt` values — a single `--cap-add NET_ADMIN` on a dedicated
profile passes that policy by construction.

### 3. Free plan and limits

Mesh requires "a Zero Trust organization with an active subscription,
including the Free plan"; the account-limits page gives 50 Mesh nodes, 50
service tokens, 30 device profiles, 500 Gateway network policies, 1,000
virtual networks with no Free/paid split for these. Service-token devices
appear as `non_identity@<team>.cloudflareaccess.com` and cannot use
identity-based policies. Whether a service-token device consumes one of the
Free plan's 50 seats is unverified (secondary sources say seats are users,
not devices).

- https://developers.cloudflare.com/cloudflare-one/account-limits/
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/mdm-deployment/parameters/
  (`service_mode` warp|1dot1|proxy|postureonly|tunnelonly; `auth_client_id`
  / `auth_client_secret`; `organization`; `auto_connect`; `onboarding`;
  `warp_tunnel_protocol` masque|wireguard; `override_warp_endpoint`)

"Always default to the FREE version only" becomes a rule: `--fleet-vpn init`
reads the account's plan and prints it, never calls a billing or
subscription route, and refuses any step whose API answer names a paid
feature (`refused:fleet-vpn:paid-feature:<step>`).

## What exists in the tree (models, not re-filed)

- `scripts/agent-identity.sh` — `id <backend>` composes
  `<platform>-<workstation>-<backend>-<utc>`; `node-name` is the shared host
  label. A session id changes per session, so it is attribution, not an
  address.
- `mcp-tool-socket` spec — one socket per lane at
  `$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock`,
  bind-mounted into that lane only, attributing a request by the socket it
  arrived on, never by what the request claims. The bus copies this exactly
  (`start_mcp_socket_server_for_lane(project_name, instance)` is the model;
  instance defaults to `default`).
- `tray-host-control-socket` spec and `tillandsias-control-wire` —
  `[u32 length][postcard]` framing, `MAX_MESSAGE_BYTES` 65,536, both
  directions enforce it.
- `tillandsias-secure-channel` — `EncryptedStream` over
  `Noise_NNpsk0_25519_ChaChaPoly_BLAKE2s` with a VERSION-BOUND PSK
  (`channel_psk`, HKDF over the release root secret). Right primitive, wrong
  pattern for a fleet: version-binding means two hosts on different releases
  cannot talk, and a coordination channel must survive a rollout. The bus
  adds a second pattern (§ Decision 4) and keeps the stream wrapper.
- `tillandsias-router-sidecar` — a static musl binary already inside the
  router container, subscribed to the tray's control socket; the natural
  home of the Mesh-side TCP relay.
- Vault per host (`tillandsias-vault-client`: `write_secret_if_absent`,
  `configure_ssh_ca_generate`, `write_ssh_role`, `read_ssh_ca_public_key`);
  `host_push_principal` mints `til:host-push:<host>`; `sshd-identity.sh`
  validates what a signer returns before installing it. Each host's Vault
  is ITS OWN — there is no fleet-wide CA, so cross-host trust cannot come
  from Vault alone; it comes from the tree (§ Decision 4).
- `tillandsias-plan` — the one binary every host and forge already has
  (`forge-plan.sh` wraps it as MCP; Codex drives it from the shell);
  `next-order`, `set-field`, `append-event`, `capability-matrix`.
- `plan/inbox/codex.md` — the file the bus retires to a pointer.

## Design summary (details in the change's design.md)

### The PoC scope

Proves, on Linux hosts (macuahuitl, lenovinha, yoga):

1. SAME HOST: a message queued by the bare-metal lane on one host is
   delivered into a Codex forge lane's mailbox, `msg recv` prints it,
   `msg ack` flips the sender's `msg status <id>` to `acked:` — no network,
   filesystem plus one Unix socket.
2. SAME LAN: the same round trip between two hosts over TCP with
   Noise XX mutual authentication pinned to `plan/fleet/peers/`, discovery
   from the directory plus mDNS hints, a `delivered` receipt from the
   receiving daemon and an end-to-end `acked` receipt from the agent.
   Acceptance demo: "the Codex forge on macuahuitl receives and ACKs a
   HEADS-UP sent by the Claude bare-metal session on yoga; yoga's
   `msg status` reads `acked`, and the ACK event lands on the row the
   message named."
3. The Cloudflare rung is RESEARCHED, not gated: 1506-euvq records whether
   WARP mode runs as a rootless sidecar sharing the router's network
   namespace and acquires a Mesh IP; 1506-t97c wires `join` to it. The
   Cloudflare rung must prove, later: (a) the sidecar registers and holds a
   `100.96.0.0/12` address across a restart; (b) a Noise session completes
   between two hosts through their Mesh IPs while the LAN path is
   deliberately unavailable (one host on a phone hotspot); (c) the account
   stays on the Free plan.

### Surfaces

`tillandsias-plan msg send|recv|ack|list|status|whoami|lint|gc` (CLI, any
harness), `forge-plan` MCP tools `msg_send`, `msg_recv`, `msg_ack`,
`msg_list`, `msg_status` (agents with MCP), `tillandsias --msg-serve` (the
resident daemon in `tillandsias-headless`: the mover on one host, the TCP
face on the LAN, the Mesh face through the router sidecar). Why the plan
binary and not a new one: it is already installed on every host and in every
forge, already wrapped as MCP, already the surface plan-only peers use, and
its `capabilities` list is how a wrapper learns a verb exists — a new binary
would need every one of those paths rebuilt.

### Addressing

An address is `<host>/<lane>`. `host` is `agent-identity.sh node-name`.
`lane` is `host` for bare-metal sessions (all sessions of one user on one
host share a mailbox: they are one uid and one trust domain) and
`<project>-<instance>` for a forge (the same label as its MCP socket
directory). `msg whoami` prints the caller's address from
`TILLANDSIAS_MSG_LANE`, exported by the launcher; nobody composes it by
hand (agent-identity's rule). The session id from `agent-identity.sh` rides
in `from_agent` for attribution; it is never what authenticates.

### Envelope

`id` (`m-<utc-compact>-<8 hex random>`), `from` and `to` addresses,
`from_agent`, `seq` (per sender lane, monotonic, persisted), `ts`, `ttl_s`
(default 86,400), `kind` (HEADS-UP|ACK|LANDED|BLOCKED|ASK|FYI),
`row` (optional order token), `in_reply_to`, `body`. Limits: body ≤ 600
bytes and ≤ 8 lines in the methodology shape; whole envelope ≤ 4,096 bytes;
both refused at `send`, never truncated. Body comes from stdin or
`--body-file`, never argv (argv is world-readable in `ps`).

### Delivery semantics (what can actually be kept)

- At-least-once: a message stays in the sender's outbox until the receiving
  daemon writes it durably and answers `stored`; retries with backoff (1 s
  doubling to 60 s) until `ttl_s`; then it moves to `dead/` and `msg status`
  prints `expired:`.
- Idempotent: the receiver keeps a seen-set of `(from, id)`; a duplicate is
  dropped silently and re-acknowledged as `stored`.
- Explicit ACK: `msg recv` moves `new/` → `cur/` (seen, not acked) and prints
  the same messages on every call until `msg ack <id>`, which moves them to
  `acked/` and sends an `acked` receipt back to the sender. Two receipt
  levels, named apart on purpose: `delivered` (the daemon stored it) and
  `acked` (an agent read it and said so).
- Ordering: per `(from lane, to lane)`, `recv` presents by `seq`; a gap is
  delivered and flagged `gap:` rather than held (at-least-once beats
  in-order for a coordination channel). No cross-sender order is promised.
- Persistence: `$XDG_STATE_HOME/tillandsias/msg/lanes/<lane>/{outbox,inbox,
  acked,dead,receipts}` on the HOST filesystem; a forge lane's directory is
  bind-mounted into its container, so a forge rebuild keeps its mailbox.
- Retention: `acked/` 7 days, `dead/` and `receipts/` 30 days; `msg gc`.
- Broadcast is `<host>/*` (every lane on one host) in the PoC; fleet-wide
  fan-out is a loop over the directory on the sender's side, not a feature.

### Transport ladder

| Rung | Address resolution | Wire | Who proves it |
|---|---|---|---|
| same host | the lane directory | filesystem move by the resident; `$XDG_RUNTIME_DIR/tillandsias/msg.sock` wakes `recv --wait` | 1506-q7ab (PoC) |
| same LAN | `plan/fleet/peers/<host>.yaml` `lan_hints:` then mDNS `_tillandsias-msg._tcp` TXT `host=`,`fp=` as a HINT only | TCP `TILLANDSIAS_MSG_PORT` (default 48640), Noise XX, control-wire framing | 1506-7tq4 (PoC) |
| Cloudflare Mesh | `plan/fleet/peers/<host>.yaml` `mesh_ip:` written by `join` | the router sidecar binds `<mesh_ip>:48640` inside the router netns and pipes bytes to `host.containers.internal:48640`; the same Noise session end to end | 1506-euvq then 1506-t97c (after the PoC) |

The daemon tries rungs in that order per peer and records which one carried
the last `stored` receipt (`msg status` prints `via:lan` or `via:mesh`).
"Handle our own tunnels" is the Noise session: it is the tunnel on every
rung; Cloudflare only supplies reachability.

### Security model

Trust roots: (1) the tree — a host is a peer iff `plan/fleet/peers/<host>.yaml`
on the checkout carries its X25519 public key; whoever can land on
linux-next is already trusted to define the fleet; (2) the mount — on one
host a lane is whoever holds that lane's directory; (3) the uid — bare-metal
sessions of one user are one domain.

- Peer authentication: `Noise_XX_25519_ChaChaPoly_BLAKE2s`, each host's
  static key generated once by `--msg-serve --mint` into its own Vault
  (`secret/fleet/msg/static`), public half plus fingerprint published as a
  YAML file in the tree by a normal landing. After the handshake the
  daemon looks the remote static up in the directory; not found →
  `refused:msg:unknown-peer:<fp>`, connection closed, nothing stored, one
  log line. mDNS never adds a peer.
- Authenticity of `from.host`: the receiving daemon overwrites nothing and
  trusts nothing from the envelope — it REFUSES an envelope whose
  `from.host` differs from the authenticated peer
  (`refused:msg:from-host-mismatch`). `from.lane` is vouched for by the
  sending host's mover, which stamped it from the mount.
- Confidentiality and integrity: ChaCha20-Poly1305 on every frame;
  ephemeral X25519 gives forward secrecy per session.
- Replay: a session's keys are fresh, so captured ciphertext is useless;
  inside a session the seen-set drops repeated ids and the per-sender
  high-water rejects `seq` far behind (a window of 1,000).
- Version skew: deliberately NOT bound into the key (unlike the control
  channel); a `proto` field in the first frame, unknown major → refused
  with the version named.
- No secrets in bodies, ENFORCED: `send` and the mover both run
  `msg_shape::secret_shaped(body)` — GitHub `ghp_`/`gho_`/`github_pat_`,
  Vault `hvs.`/`hvb.`, `AKIA`, `sk-`, `-----BEGIN … PRIVATE KEY`, `Bearer `,
  three-part `eyJ` JWTs, and any base64/hex run ≥ 40 chars — and refuse
  `refused:msg:secret-shaped:<pattern>`. The fixture proves both sites
  refuse by sending a body that only the second site could catch (a lane
  writing straight into its outbox directory).
- The Mesh relay in the router sidecar is a byte pipe: it sees ciphertext,
  binds only the Mesh IP, and never the enclave bridge address.

Threat table:

| Attacker | Can | Cannot | Because |
|---|---|---|---|
| a device on the same switch (passive) | see that hosts talk, TCP 4-tuples, message sizes | read bodies, learn lanes | AEAD on every frame |
| a device on the same switch (active, spoofs mDNS) | make a daemon try an address | become a peer, receive a message, cause a false `delivered` | mDNS is a hint; XX pins the static key to the directory |
| a device on the LAN replaying captured frames | nothing | re-deliver a message | per-session keys; seen-set |
| a compromised forge (lane) | send as its own lane; read its own inbox; fill its own outbox | send as another lane, read another lane's inbox, reach the network | it holds one directory; the mover stamps `from.lane` from the mount; the daemon runs on the host |
| a peer host that is compromised | send any message as itself, to anyone | impersonate a third host | `from.host` must equal the authenticated static |
| someone who can land on linux-next | add a peer | — | that is the fleet's trust root already (branch discipline, hooks) |
| a Cloudflare-side observer | see Mesh IP pairs and sizes | read bodies | the Noise session is end to end |
| a process with the user's uid on a host | anything that uid can | — | out of scope: uid is the domain |

### The ledger keeps the record

The bus is fast and acknowledged; the ledger is durable. `msg send --row
<order>` names the row; `msg ack --row` appends the `ack` event on that row
(the same `ACK: <msg-id>` the Codex inbox asked for, written by the tool
rather than by hand); an expiry writes an `undelivered` event on the row.
`plan/inbox/codex.md` becomes a ten-line pointer to `msg recv`, and
`plan_only_peers` gains `msg recv` as step 0 with the ledger unchanged as the
record.

## Open questions for the operator

1. Is a second granted capability acceptable on a dedicated sidecar
   container (`--cap-add NET_ADMIN` plus `/dev/net/tun`, no other
   container changes), or must the Cloudflare rung wait for a
   capability-free path that does not exist today?
2. Should bare-metal sessions on one host share ONE mailbox (`<host>/host`,
   as designed, because they are one uid), or do you want a mailbox per
   session name?
3. Port 48640 for the LAN daemon and mDNS advertisement on by default — or
   directory-only discovery with mDNS off until you say so?
4. May a host's public msg key be committed to the tree under
   `plan/fleet/peers/`, or do you prefer a separate keys repository?
5. Which two hosts run the LAN acceptance demo first (design assumes yoga
   → macuahuitl)?

## Provenance

Every Cloudflare page above was fetched on 2026-09-29 from public
documentation; community pages are marked secondary; no account was created
and no credential was handled. Repository facts were read at the merge of
`worktree-agent-ae9525e76ba6c53c8` and `work/1505-kyx8` onto
linux-next `52e3bc32e`: `build_router_run_args`, `ensure_router_running`,
`start_mcp_socket_server_for_lane` (tillandsias-headless main.rs);
`weakening_hardening_flag`, `option_takes_value` (tillandsias-podman
policy.rs); the `cap_add` removal note (container_spec.rs, 972-6vaj);
`EncryptedStream`, `channel_psk` (tillandsias-secure-channel);
`host_push_principal` (vault_bootstrap.rs); `tillandsias-router-sidecar`
main.rs; `plan/inbox/codex.md` at `fab17ec02`; `plan_only_peers` and
`sibling_heads_up_protocol.size_budget` in the methodology.
