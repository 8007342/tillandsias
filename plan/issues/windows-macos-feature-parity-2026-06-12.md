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
