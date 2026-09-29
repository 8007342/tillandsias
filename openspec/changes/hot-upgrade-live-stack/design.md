# Design: hot-upgrade under a live stack

@trace order:1490-gttj

## Context

Three binaries, three lifetimes. On Linux the headless/tray process is the
sole owner of a podman stack that outlives nothing: its own exit stops every
managed container (`graceful_shutdown_async`, `main.rs:19692`). On macOS and
Windows the tray owns a guest (VM in-process; WSL distro terminated on quit)
that in turn runs a headless daemon owning the containers. In every case the
binary's lifetime is coupled to the stack's lifetime by decisions made for the
ephemeral doctrine (900-z3kv), not for upgrades.

Containers are not versioned by name; images are (`:v<VERSION>`). The binary
decides what to run by name-presence, so a running container is opaque to the
binary that inherits it — and, as the 2026-09-29 measurement showed, so is a
toolbox that merely shares the prefix.

`host-state-lifecycle` already owns the tiers and the KEEP table. This design
does not add a tier; it changes what SOFT does to the running stack.

## Goals / Non-Goals

**Goals**
- A running forge and the agent inside it are never stopped, restarted or
  disconnected by an upgrade of either binary.
- Every upgrade outcome is one of `upgraded`, `up-to-date`,
  `deferred:<reason>`, `refused:<reason>` — printed, logged, shown by the tray.
  Never silent.
- Version skew between binary, shared stack, forge images and guest is
  measurable at any moment (`--diagnose`) and bounded by a declared window.
- SOFT keeps the Vault store (already), plus the images, the containers, the
  VM/distro and the running forges (new).
- The background check is opt-out, cheap, and never interrupts: it downloads
  and stages; it applies only through the SOFT path when idle.
- Nothing Tillandsias did not create is ever stopped or removed.

**Non-Goals**
- Live-patching a running process. An upgrade is always a new process that
  inherits state.
- Migrating in-flight PTY sessions across a guest daemon re-exec (v1 accepts
  that an open host terminal reconnects; the forge process inside is untouched).
- Rebuilding forge images in the background.

## Decisions

### D1. Upgrade = handoff, not restart

A new instance started with `--upgrade-handoff` (set by `--update` and by the
installer's update path) contacts the old instance over the existing control
socket with `HandoffRequest { new_pid, new_version }`. The old instance:
1. stops accepting new lane launches;
2. writes a handoff manifest (`state/handoff.json`: owner uuid, version,
   managed container names + image tags + roles, open lane leases), fsync'd;
3. releases the singleton lock WITHOUT calling `graceful_shutdown_async`;
4. exits 0.

The new instance acquires the lock, reads the manifest, and **adopts**: each
listed container is checked (`podman inspect`, owner label) and registered in
its stack model as if it had launched it. The singleton's SIGTERM path
(`singleton.rs:192 terminate_process`) stays for the non-handoff case and is
logged as `takeover:kill` so the two are distinguishable.

If the old instance does not answer within 5 s (older binary, hung), the new
instance refuses: `refused:upgrade:no-handoff-peer`, prints the relaunch path
(`tillandsias --quit && tillandsias`), and never falls through to the kill
path on its own.

### D2. Ownership by label, name as fallback

`podman run` / `volume create` / `network create` gain
`--label io.tillandsias.owner=<installation-uuid-v1>`,
`--label io.tillandsias.version=<VERSION>`,
`--label io.tillandsias.role=<forge|git|vault|proxy|router|nix-cache|inference|browser|ssh-sidecar|observatorium|status-check|web>`.
The predicates — `is_stack_managed_name` (`main.rs:7497`), `reset_guest_scope`
(`:10029`), `shutdown_escalation_targets` (`:7478`) and the `list_containers("tillandsias-")`
calls in `graceful_shutdown_async` — become `is_owned(obj)`: label match
first; a missing label falls back to the current name predicate ONLY for
objects without any label, logged as `legacy-unlabelled`. An object carrying
a toolbox label (`com.github.containers.toolbox`) is never owned even if it
carries ours. The existing proxy label `tillandsias.ca-generation`
(`main.rs:3713`) stays as it is.

### D3. Skew policy: compatibility window, drain-then-swap

`tillandsias-core::version_guard` gains `compatible(binary, image) -> Window`
with three answers: `Same`, `Compatible` (same Major.Minor, image date within
`WINDOW_DAYS = 14` of the binary's), `Incompatible`. After adoption:
- forge containers: never touched; their skew is reported;
- shared containers `Compatible`: keep; report;
- shared containers `Incompatible` with **no running forge depending on it**
  (`cleanup_shared_stack_if_no_running_forge`, `main.rs:7776`, already knows
  this): drain-then-swap (stop, recreate on the new tag, re-run readiness);
- shared containers `Incompatible` with a dependent forge:
  `deferred:skew:<name>`; the swap runs when the dependency count reaches
  zero.
`ensure_router_running` (`main.rs:6241`) is the existing precedent for
comparing the running image to the version tag; the policy generalises it.

### D4. Control wire: negotiate, do not assert

`Hello` and `HelloAck` carry `wire_version` today; add `wire_version_min` on
both. Accept when `[min_peer, ver_peer]` and `[min_self, ver_self]`
intersect; speak the highest common version. A refused peer receives
`refused:wire:incompatible:<peer-range>:<self-range>` and the host surfaces
the drain-then-swap remedy. The two fixture sites hard-coding `wire_version: 2`
(`control_dispatch.rs:268,618`) use the constant.

### D5. Guest hot-install: atomic rename + `KillMode=process`

Both headless unit files (`vz.rs:1240`, `wsl_lifecycle.rs:1875`) set
`KillMode=process`. The install writes `tillandsias-headless.new` and
`rename(2)`s it over the destination (no ETXTBSY: the running inode stays
alive), then `systemctl restart` kills only the daemon's own PID. Whether
conmon and the container processes survive is an EXPERIMENT, not an
assertion: the packets' litmus counts `podman ps -q` before and after and
requires equality.

Windows: `inject_stale_guest_wiring` (`wsl_lifecycle.rs:1083`) drops the
`systemctl stop` (`:1124`) and uses the rename install.

macOS: the fetch oneshot becomes a `.path` unit watching the virtio-fs share,
so a new stage triggers the same install without a reboot, and the
`releases/latest` fallback (`vz.rs:1122`) is pinned to `v<host-version>`.

macOS VM out-of-process: because the VM lives in the tray process
(`vz.rs:2884-2885`), a host tray upgrade cannot keep the VM running today.
This is research (1490-cvqe): (a) a `tillandsias-vmhost` helper process that
owns the VM and survives tray exit, adopted by the next tray over the existing
vsock plus a local socket; or (b) accept that on macOS a HOST upgrade drains
the guest (loud, `deferred:vm-in-process`) while a GUEST upgrade is hot. The
first deliverable is that decision with measurements.

### D6. `--update` and the 24-hour check

`tillandsias --update [--check-only] [--channel stable|next]`:
1. resolves the release by channel tag (never `releases/latest`; `versioning`
   spec "Rolling channel tags");
2. downloads to `downloads/updates/<version>/` (recorded in the manifest per
   `host-state-lifecycle`), verifies checksum and signature when
   `binary-signing` provides one;
3. installs atomically beside the running binary (`rename`), then execs the
   new binary with `--upgrade-handoff` (D1).
The tray runs the same code on a timer with period
`UpdatesConfig.check_interval_hours` (default 6 → 24 to match the request);
`0` disables; `check_on_launch` is honoured. The background path performs
steps 1-2 only; step 3 runs when the stack is `idle` (no lane launched in the
last 10 minutes, no interactive PTY session) or when the operator clicks
*Install update*. A staged update older than 7 days is re-verified. Downgrades
are refused by `downgrade_refusal` (`main.rs:2869`).

### D7. SOFT on Linux: label-keyed stale cleanup, never `podman system reset`

`scripts/cleanup-stale-tillandsias.sh [--dry-run] [--all-versions]` and the
same body inside `run_reset_state`: remove EXITED containers with
`io.tillandsias.owner`, owned volumes no container references, owned networks
with no endpoints, and images `localhost/tillandsias-*:v<X>` where `<X>` is
neither the current VERSION nor referenced by a running container. Running
owned containers are listed, never touched. Anything carrying a toolbox label
is skipped and named. `scripts/e2e-step2-linux.sh`, `run_smoke.sh` and the
skills switch to it by default; `podman system reset --force` becomes the
Linux HARD tier (`TILLANDSIAS_INSTALL_RESET=hard` / `--hard-reset`, per-run
approval as the guest HARD) and stays the default of
`smoke-curl-install-and-test-e2e` only, whose contract IS the pristine host.

## Risks / Trade-offs

- Adoption trusts a manifest written by an older binary. Mitigation: the new
  instance re-derives everything from `podman inspect` and treats the manifest
  as a hint; a mismatch is `refused:upgrade:manifest-mismatch`.
- The compatibility window is a policy number. Mitigation: spec'd with a
  litmus; `--diagnose` prints the measured skew.
- `KillMode=process` may leave a wedged podman child alive on a real crash.
  Mitigation: the straggler probe runs on daemon start inside the guest.
- Background staging uses disk and bandwidth. Mitigation: HEAD first; one
  staged version at a time; `check_interval_hours = 0` opts out.
- Moving `podman system reset` to a Linux HARD tier changes the consent shape
  on Linux (no HARD existed). Mitigation: it inherits the exact 1443-bs9z
  per-run approval; the operator can rule otherwise before 1490-pguh lands.

## Migration Plan

1. Labels first (1490-nczm): every new object is labelled; predicates gain the
   label branch with name fallback. No behaviour change for existing stacks.
2. Stale cleanup (1490-pguh) is independent of the handoff and lands next,
   removing `podman system reset` from SOFT and from the skills.
3. Handoff + adopt on Linux (1490-52m5); skew policy (1490-d45z).
4. Wire window (1490-acd5), then guest hot-install on Windows (1490-j6du) and
   the macOS guest path + research (1490-cvqe).
5. `--update` + background check (1490-aqc7) last, on top of the SOFT path.
6. Sync deltas into the main specs; archive.

## Open Questions

- Does `systemctl restart tillandsias-headless.service` with `KillMode=process`
  leave podman containers running in both guests? (Measured by 1490-j6du.)
- Can the macOS VM be moved out-of-process without losing the entitlement
  story? (1490-cvqe.)
- Should the window be date-based (14 days) or Major.Minor-only? The
  versioning spec's monotonic CalVer supports either.
- Linux HARD tier: does the operator want `podman system reset --force`
  behind the per-run approval, or removed from the binary entirely (script
  only)? Recorded in the host-state-lifecycle delta; 1490-pguh implements the
  approval form unless ruled otherwise.
