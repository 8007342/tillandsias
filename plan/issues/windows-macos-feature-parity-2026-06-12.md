# Windows and macOS Feature Parity Restoration

trace: plan.yaml future_intentions,
       plan/steps/58-future-intentions-drain.md,
       plan/issues/ACTIVE.md

Status: ready
Owner host: macos+windows
Coordinator: linux
Capability tags: [macos, windows, tray, host-shell, vm-layer, vault, podman, testing]

## Objective

Restore real Windows and macOS parity with the Linux headless/tray runtime. The
target is not "the crates compile"; it is an operator-visible workflow where the
native tray can provision the VM/WSL substrate, report truthful state, launch the
forge, complete GitHub Login through the Vault-native flow, list projects, and
attach an interactive shell without stale menu state or false success claims.

## Current State

The broad future intention is now a claimable packet rather than an orphaned
note. Current evidence says the parity gap is concentrated in four surfaces:

1. Substrate readiness: macOS VM provisioning now reaches
   `phase=Ready podman_ready=true`, while Windows cold-provision and service
   unit readiness have their own queue packets.
2. GitHub Login: macOS is blocked by the Linux-owned aarch64 Vault published-port
   reachability packet in `plan/issues/ACTIVE.md`; the host-shell launch route
   must then switch from bare `gh auth login` to orchestrated
   `tillandsias-headless --github-login`.
3. Menu truthfulness: native tray menus must derive their enabled/disabled state
   from live host-shell/control-wire state, not stale spec-era assumptions.
4. End-to-end evidence: every "done" claim needs host-specific smoke evidence,
   including project listing and attach-shell behavior after GitHub Login.

## Work Waves

### Wave A - Blocker Closure

- macOS waits on `enclave/macos-vault-unreachable-via-publish-aarch64`
  (`plan/issues/ACTIVE.md`). Linux has verified the obvious listener and host CA
  path are already correct in the current tree; the remaining useful evidence is
  from the aarch64 VM: published-port transport diagnostics and a successful
  `curl --cacert /tmp/tillandsias-ca/intermediate.crt
  https://127.0.0.1:8201/v1/sys/health?standbyok=true`.
- Windows must keep the cold-provision/headless service packets synchronized in
  `plan/issues/windows-next-work-queue-2026-05-25.md`.

### Wave B - Launch Route Parity

- macOS and Windows tray GitHub Login entries launch the orchestrated
  headless flow, not bare `gh`.
- PTY environment includes the runtime-lane variables needed by the in-VM
  headless process (`XDG_RUNTIME_DIR` where applicable, plus terminal metadata).
- Shared host-shell changes preserve wire compatibility and are mirrored across
  both native trays.

### Wave C - Menu And State Truth

- Disabled/enabled menu rows are backed by live control-wire or host-shell state.
- Stale spec-era labels are removed or routed through the current shared menu
  contract.
- Failure states expose actionable diagnostics rather than gray terminals,
  silent exits, or optimistic "created" claims.

### Wave D - End-To-End Acceptance

- macOS m8 user-attended smoke passes: provision, GitHub Login, project list,
  forge launch, and attach shell.
- Windows WSL2 smoke passes the corresponding workflow after Smart App Control
  and cold-provision blockers remain cleared.
- Both host queues record focused unit tests plus the operator-visible smoke
  evidence before claiming parity complete.

## Next Actions

1. Linux: keep the aarch64 Vault reachability packet current. If no Linux-side
   code gap is found, record it as blocked on an aarch64 VM probe with the exact
   command above.
2. macOS: after Wave A is cleared, land the host-shell GitHub Login route and
   PTY environment changes together, then run m8.
3. Windows: keep `windows-next` synchronized with `linux-next` and verify the
   cold-provision/headless unit path before taking optional UX work.
4. Coordinator: do not mark this packet done until both host queues cite concrete
   smoke evidence for GitHub Login, project listing, forge launch, and attach.

## Events

- type: shaped
  ts: "2026-06-20T05:44:05Z"
  agent_id: "linux-macuahuitl-codex-20260620T054405Z"
  host: linux
  note: >
    Drained the remaining plan.yaml future intention into this structured
    cross-host parity packet. Implementation remains split by host queue and by
    the active macOS Vault blocker.

- type: coordinator_review
  ts: "2026-06-20T08:42Z"
  agent_id: "linux-macuahuitl-claude-20260620T0842Z"
  host: linux
  note: >
    Coordinator pass (2026-06-20T08:42Z). Sibling state: windows-next at
    a3c8b23d (ancestor of linux-next — in sync, 0 drift); osx-next at d829808d
    (ancestor of linux-next — in sync, 0 drift). SSH unavailable in Cowork
    session; fetch and push both fail. Local linux-next is 2 commits ahead
    (nanoclawv2 Slice 3 + plan packet, push-blocked since 08:33Z cycle).

    Wave A (vault aarch64 blocker): `enclave/macos-vault-unreachable-via-publish-aarch64`
    remains OPEN. Code inspection confirms: (1) vault.hcl binds 0.0.0.0:8200 ✓;
    (2) CA cert path /tmp/tillandsias-ca/intermediate.crt ✓; (3) vault_bootstrap.rs
    launches with `--userns keep-id -p 127.0.0.1:8201:8200 --network tillandsias-enclave`.
    Root cause is aarch64 rootlessport failing to forward bytes through the bridge
    netns despite accepting the TCP SYN. Potential next steps for Linux worker (requires
    aarch64 VM): (a) check `podman version` and `rootlessport` binary on the VM;
    (b) try `--network=pasta` instead of bridge+publish to bypass rootlessport
    entirely (pasta handles port forwarding in userspace without the bridge netns
    indirection); (c) verify whether `slirp4netns:port_handler=slirp4netns` resolves
    the issue as a fallback. No code change shipped — aarch64 VM probe required to
    confirm before modifying vault launch args. Filed for next aarch64-capable session.

    Wave B (github login route): blocked on Wave A. Lease `ghlogin-route-orchestrated-20260620T0134Z`
    still held by macOS operator; code is shaped (launch_spec → orchestrated --github-login)
    but intentionally not shipped alone. No change.

    Wave C / D: blocked on Waves A + B. No change.

    Windows sync: a3c8b23d is 21 commits behind linux-next. Step-36 Vault keychain
    blocked on linux step-32 (true-rekey) — not yet landed. No Windows work eligible.

    NanoClawV2 (adjacent): Slices 1-3 complete on local linux-next (push-blocked).
    Slice 4 (smoke coverage) is the next packet; not started this cycle due to
    push-blocked state and Cowork session SSH constraint.

    Coordinator decision: no Wave A code action possible without aarch64 VM access.
    Packet remains ready/in-progress awaiting operator aarch64 probe.
