# Hot-upgrade the Tillandsias binary under a live guest and container stack

@trace order:1490-gttj

## Why

The operator's request (2026-09-29, verbatim in `plan/index.d/` order
1490-gttj): the SOFT reset should be a quick upgrade of the HOST tillandsias
binary and the GUEST tillandsias binary, without relaunching the containers or
the VM. Agents working inside forges must not be disturbed; users should update
transparently (`tillandsias --update`, or a silent 24-hour background check);
and builds should be re-launchable without killing anyone's forge. Second
request, same session: replace `podman system reset` in the skills and build
scripts with a cleanup of the stale Tillandsias containers only.

`openspec/specs/host-state-lifecycle/spec.md` (1437-8c6p, amended 1438-pk9j and
1443-bs9z) already defines the SOFT tier (`--reset-state`; both Linux flags are
SOFT) against HARD (`--reset-guest` on guest regimes), the three Vault-store
dispositions (`Verified:KEEP`, `Unverified:KEEP`, `Absent:REINIT-AT-INIT`) and
the preserved operator-data set. What it does NOT yet say is that a SOFT reset
keeps the running stack: today its Linux body still runs `podman system reset
--force` and its guest bodies "wipe the previous containers". This change
modifies that requirement so the SOFT tier becomes the hot-upgrade tier.

**Motivating measurement (lenovinha, 2026-09-29).** A Linux SOFT reset
(`tillandsias --reset-state`) ran `podman system reset --force`
(`crates/tillandsias-headless/src/main.rs:10172-10175`, `run_reset_state`).
It destroyed the two non-Tillandsias fedora-toolbox containers
`tillandsias-builder` and `tillandsias-nix` — they share the `tillandsias-`
name prefix and nothing distinguishes them from ours — and every running forge.
The Vault store survived as the spec promises (`Verified:KEEP`; 134 files before
and after). The store is safe; the stack, the toolboxes and the agents are not.
That is the case for ownership by label rather than by name prefix, and for a
SOFT tier that adopts instead of wipes.

The investigation (re-verified against `origin/linux-next` 3e4b7fb58,
2026-09-29; every span below was read):

**Linux host (podman).**
- A second non-CLI instance SIGTERMs the first through the singleton lock
  (`crates/tillandsias-core/src/singleton.rs:134-146` calls
  `terminate_process`, defined at `:192`). The first then runs
  `graceful_shutdown_async` (`crates/tillandsias-headless/src/main.rs:19692`),
  which `podman stop`s every running container passing `is_stack_managed_name`
  (`main.rs:7497`, via `shutdown_escalation_targets` `:7478`) and escalates to
  SIGKILL. Forges run `--rm` (`build_opencode_forge_args`, `main.rs:8027`;
  status-check forge `:7872`), so a stop is the loss of the forge. The ONLY way
  to run a new binary today is to kill every agent's forge first. 1452-ihxp is
  the same loss through the lane-launch path.
- Startup reuses running shared containers **by name only**: vault
  (`vault_bootstrap.rs:826`), proxy (`ensure_proxy_running`, `main.rs:3836`),
  nix-cache (`main.rs:6419`), catalog services (`container_deps.rs:511`). Only
  `ensure_router_running` (`main.rs:6241`) compares the running image against
  the version tag. After a binary swap the shared stack silently keeps running
  the OLD image while new forges get `localhost/tillandsias-forge:v<NEW>`
  (`versioned_image_tag`, `main.rs:2348`). Skew is neither detected nor
  declared.
- Containers carry **no ownership label**. Images do
  (`io.tillandsias.image.{name,version,source-digest,layer-policy}`,
  `crates/tillandsias-core/src/image_builder.rs:27-28,154,162`, applied at
  `main.rs:9807-9809`). The single container label in the tree is the proxy's
  `tillandsias.ca-generation` (`main.rs:3712-3713`, order 472), which names a
  CA, not an owner. Every ownership decision is a name test:
  `is_stack_managed_name` (`main.rs:7497`, narrowed by 936-kdev after the same
  toolbox was killed at install-validation) and `reset_guest_scope`
  (`main.rs:10029`, the bare `tillandsias-` prefix).
- No updater exists. `UpdatesConfig` (`crates/tillandsias-core/src/config.rs:328`,
  `check_interval_hours` default 6 at `:347`, `check_on_launch=true`) is
  serialised into `config.toml` (`:678-679`) and read by nothing;
  `openspec/specs/update-system/spec.md` is `obsolete` (1397-eppt). Downgrades
  are already refused by `downgrade_refusal` (`main.rs:2869`).

**macOS host (Virtualization.framework).**
- The VM is created inside the tray process
  (`VZVirtualMachine::initWithConfiguration`,
  `crates/tillandsias-vm-layer/src/vz.rs:2884-2885`) and cannot outlive it.
  Quit is `quit_with_drain` (`crates/tillandsias-macos-tray/src/action_host.rs:1211`)
  which sends `VmShutdownRequest` (`vz.rs:722`) — the headless stops every
  container — then stops the VM. `openspec/specs/vm-provisioning-lifecycle/spec.md:168`:
  "There SHALL be no opt-out for the shutdown-on-tray-exit contract in v1."
- The guest binary is staged through a virtio-fs share
  (`crates/tillandsias-macos-tray/src/guest_binary.rs:232 stage_guest_binary`)
  and installed by `tillandsias-headless-fetch.service` (unit written at
  `vz.rs:1203`) **only at boot**. The fetch script falls back to
  `releases/latest` (`vz.rs:1122`) — a moving target, unpinned to the host
  version. Neither the fetch unit (`vz.rs:1210`) nor the headless unit
  (`vz.rs:1240`) sets `KillMode=`.

**Windows host (WSL2).**
- Quit runs `WslLifecycle::graceful_shutdown` (`wsl_lifecycle.rs:665`) →
  `WslRuntime::stop` (`crates/tillandsias-vm-layer/src/wsl.rs:1120`) →
  `wsl --terminate`.
- A new tray adopts a registered distro (`reconcile_adopted_guest`,
  `wsl_lifecycle.rs:999`) and on version mismatch `inject_stale_guest_wiring`
  (`:1083`) **stops** `tillandsias-headless.service` (`:1124`, comment:
  overwriting a running ELF is ETXTBSY), overwrites via `cat > path`
  (`:2115`, `:2154`), then restarts (`:1133`). Every vsock/PTY session drops.
  The unit file (`[Service]` at `:1813`/`:1875`) sets no `KillMode=`, so the
  default `control-group` may take conmon and the containers with it —
  UNMEASURED.

**Control wire (both VM platforms).**
- `WIRE_VERSION = 4` (`crates/tillandsias-control-wire/src/lib.rs:86`). A
  mismatch is fatal on every side: the guest server
  (`crates/tillandsias-headless/src/vsock_server.rs:949`), the macOS bridge
  (`crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs:229`), the Windows
  client (`crates/tillandsias-host-shell/src/vsock_client.rs:182`).
  `build_version` is carried (`lib.rs:400,408`) but never enforced. Two fixture
  sites hard-code `wire_version: 2` (`control_dispatch.rs:268,618`). There is
  no declared compatibility window, so a wire bump forces a guest restart with
  no path to drain first.

**`podman system reset --force` call sites** (executable, not comments):
`scripts/e2e-step2-linux.sh:7`, `run_smoke.sh:16`, `main.rs:10172-10175`
(the SOFT body — this change removes it from SOFT), `main.rs:3023-3067`
(one-shot overlay-corruption self-heal — stays). Prose that instructs it:
`skills/build-install-and-smoke-test-e2e/SKILL.md:16,49,274,337`,
`skills/initialize-bare-metal-host/SKILL.md:90`,
`skills/meta-orchestration/SKILL.md:1973`,
`skills/smoke-curl-install-and-test-e2e/SKILL.md:3`. Prior art:
`scripts/selective-tillandsias-reset.sh` (order 222) removes ALL containers and
volumes, not ours only.

## What Changes

- **MODIFIED** `host-state-lifecycle` "Destructive reset destroys derived
  state and preserves operator data": the SOFT tier becomes the hot-upgrade
  tier. SOFT keeps running owned containers (adopted by the new binary),
  removes only STALE owned objects by label, never runs `podman system reset`,
  and never touches an object it does not own. The full podman wipe moves to a
  Linux HARD tier with the same per-run approval the guest HARD already has.
  The KEEP table gains the running stack, the VM/distro and the running
  forges.
- **ADDED** to `app-lifecycle`: an *upgrade handoff* — a new instance started
  with `--upgrade-handoff` (or by `--update`) takes over WITHOUT the old
  instance stopping managed containers; the new instance ADOPTS them.
- **ADDED** to `app-lifecycle`: ownership labels
  (`io.tillandsias.owner`, `io.tillandsias.version`, `io.tillandsias.role`)
  on every container, volume and network; ownership predicates key on the
  label with the name predicate as a logged fallback.
- **MODIFIED** `app-lifecycle` "shutdown_all removes containers AND destroys
  the enclave network": the sweep is label-keyed and is skipped on the
  handoff exit.
- **ADDED** to `app-lifecycle`: an explicit shared-stack skew policy
  (compatibility window; drain-then-swap only with zero dependent forges).
- **MODIFIED** `vm-provisioning-lifecycle` "Tray exit triggers graceful
  drain": exactly one exception, the upgrade handoff; an in-process VM refuses
  it loudly.
- **ADDED** to `vm-provisioning-lifecycle`: guest hot-install by atomic
  rename under `KillMode=process`, pinned to the host version.
- **MODIFIED** `vsock-transport` "Framing and handshake are identical to the
  Unix-socket transport": `Hello`/`HelloAck` negotiate within a declared
  window instead of asserting equality.
- **MODIFIED** `update-system`: `obsolete` → `draft`; **ADDED**
  `tillandsias --update`, the 24-hour opt-out background check, silent install
  through the SOFT path, and the LOUD fallback.
- **Skills and build scripts**: `podman system reset --force` is replaced by
  a label-keyed stale cleanup everywhere except the clean-room
  release-acceptance gate, which keeps it as the Linux HARD tier.

## Capabilities

### Modified Capabilities
- `host-state-lifecycle` — SOFT is hot-upgrade; Linux HARD; KEEP table.
- `app-lifecycle` — handoff, ownership labels, label-keyed sweep, skew policy.
- `vm-provisioning-lifecycle` — handoff exception; guest hot-install.
- `vsock-transport` — compatibility window and negotiation.
- `update-system` — `--update`, background check, silent SOFT, loud fallback.

## Impact

- Crates: `tillandsias-core` (singleton handoff, label constants, updater
  config), `tillandsias-headless` (adopt-on-start, label-keyed predicates,
  `--update`, `--upgrade-handoff`, skew report, stale cleanup body),
  `tillandsias-control-wire` (window), `tillandsias-vm-layer` (unit files,
  atomic install), `tillandsias-macos-tray` (handoff; VM out-of-process is a
  prerequisite and is scoped as research), `tillandsias-windows-tray`
  (reconcile without stop), `tillandsias-host-shell` (negotiation).
- Scripts/skills: `scripts/e2e-step2-linux.sh`, `run_smoke.sh`,
  `skills/build-install-and-smoke-test-e2e`, `skills/initialize-bare-metal-host`,
  `skills/meta-orchestration`, `skills/smoke-curl-install-and-test-e2e`,
  `build.sh` install-validation instance.
- Risk: the macOS host half depends on hosting the VM outside the tray
  process, a larger change than the others, filed as research first.
- Open ruling: this change proposes that `podman system reset --force` become
  a Linux HARD tier (per-run approval). The operator has ruled on guest HARD
  consent (1443-bs9z) but not on a Linux HARD; the delta records the proposal
  and the consent shape it inherits.
