# Tasks: hot-upgrade under a live stack

Each section is one plan order under milestone 1490-gttj. Nothing here is
implemented yet.

## 1. Container ownership labels (1490-nczm)

- [ ] 1.1 Add `io.tillandsias.owner`, `io.tillandsias.version`, `io.tillandsias.role` label constants to `crates/tillandsias-core` beside the image labels in `image_builder.rs:27-28`.
- [ ] 1.2 Apply them on every `podman run`, `volume create`, `network create` emitted by `tillandsias-headless` (forge `main.rs:7986`, proxy `:3678`, git `:4816`, inference `:5780`, router `:6073`, nix-cache `:6354`, catalog `:3632`, ssh sidecar `:12751`, web `:19873`, vault `vault_bootstrap.rs`, mirror `remote_projects.rs:291,761`).
- [ ] 1.3 Replace `is_stack_managed_name`, `reset_guest_scope`, `shutdown_escalation_targets` and the `list_containers("tillandsias-")` sweeps with `is_owned(obj)`: label first, name fallback logged as `legacy-unlabelled`; toolbox-labelled objects never match.
- [ ] 1.4 `scripts/test-container-ownership-labels.sh`: launches a labelled container with a foreign name and an unlabelled toolbox-labelled container named `tillandsias-builder-test`; asserts the sweep lists the first and refuses the second.

## 2. Label-keyed stale cleanup replaces `podman system reset` (1490-pguh)

- [ ] 2.1 `scripts/cleanup-stale-tillandsias.sh` (label-keyed; toolbox-safe; `--dry-run`; exit 0 on an empty store; idempotent).
- [ ] 2.2 `run_reset_state` (`main.rs:10128`) runs the same cleanup instead of `podman system reset --force` (`:10172-10175`); `podman system reset --force` moves behind the Linux HARD tier with per-run approval.
- [ ] 2.3 Switch `scripts/e2e-step2-linux.sh:7`, `run_smoke.sh:16`, `skills/build-install-and-smoke-test-e2e`, `skills/initialize-bare-metal-host`, `skills/meta-orchestration` to the cleanup; keep `podman system reset --force` as the default of `skills/smoke-curl-install-and-test-e2e` only, named as HARD.
- [ ] 2.4 `scripts/test-cleanup-stale-tillandsias.sh`: seeds a toolbox-labelled container, an exited owned container, a running owned container; asserts only the exited one is removed and the toolbox is named as skipped.

## 3. Linux host handoff + adopt (1490-52m5)

- [ ] 3.1 `--upgrade-handoff` flag; `HandoffRequest`/`HandoffAck` on the control socket.
- [ ] 3.2 Old instance: stop accepting lanes, write `state/handoff.json`, release lock, exit 0 without `graceful_shutdown_async`.
- [ ] 3.3 New instance: adopt from `podman inspect` (manifest as hint); `refused:upgrade:no-handoff-peer` / `manifest-mismatch` on failure; the SIGTERM path logged as `takeover:kill`.
- [ ] 3.4 `scripts/test-host-upgrade-handoff.sh`: forge running a sleeping process; swap binary; assert container id and PID unchanged and `--diagnose` lists it as adopted.

## 4. Shared-stack skew policy (1490-d45z)

- [ ] 4.1 `version_guard::compatible()` and `WINDOW_DAYS`.
- [ ] 4.2 Post-adopt sweep: report per container; drain-then-swap only with zero dependents.
- [ ] 4.3 `--diagnose` prints a skew table.
- [ ] 4.4 `scripts/test-shared-stack-skew.sh`.

## 5. Control-wire compatibility window (1490-acd5)

- [ ] 5.1 `WIRE_VERSION_MIN_PEER`; `wire_version_min` in `Hello`/`HelloAck`.
- [ ] 5.2 Negotiation in `vsock_server.rs:949`, `pty_vsock_bridge.rs:229`, `vsock_client.rs:182`.
- [ ] 5.3 `control_dispatch.rs:268,618` use the constant.
- [ ] 5.4 `cargo test -p tillandsias-control-wire wire_window`: overlap, no-overlap refusal message, highest-common selection.

## 6. Guest hot-install on Windows/WSL2 (1490-j6du)

- [ ] 6.1 `KillMode=process` in the unit (`wsl_lifecycle.rs:1875`); atomic rename install replaces `cat > path` (`:2115`) + `systemctl stop` (`:1124`).
- [ ] 6.2 `reconcile_adopted_guest` no longer stops the unit before injecting.
- [ ] 6.3 MEASUREMENT: `podman ps -q` inside the distro before/after `systemctl restart` — equal sets.
- [ ] 6.4 Tray quit path gains the handoff exception (no `wsl --terminate` when exiting as the old side of `--upgrade-handoff`).

## 7. macOS guest hot-install + VM-out-of-process research (1490-cvqe)

- [ ] 7.1 Fetch oneshot becomes a `.path` unit; atomic rename install; `KillMode=process` (`vz.rs:1240`); `releases/latest` (`vz.rs:1122`) pinned to `v<host-version>`.
- [ ] 7.2 Research memo `plan/issues/macos-vm-out-of-process-research-2026-09-29.md`: can `VZVirtualMachine` be hosted by a helper that survives tray exit? Decision + measurements.
- [ ] 7.3 Until 7.2 lands, a host handoff on macOS reports `deferred:vm-in-process` and offers the drain relaunch.

## 8. `tillandsias --update` + 24 h background check (1490-aqc7)

- [ ] 8.1 Resolve by channel tag; download; verify; stage under `downloads/updates/` and record in the manifest.
- [ ] 8.2 Atomic install + exec `--upgrade-handoff`.
- [ ] 8.3 Timer in the tray from `UpdatesConfig`; default 24 h; `0` disables; idle gate before install.
- [ ] 8.4 Every outcome printed as `upgraded|up-to-date|deferred:<reason>|refused:<reason>`.
- [ ] 8.5 `scripts/test-update-command.sh` against a local `file://` release fixture.

## 9. Spec sync

- [ ] 9.1 Sync the five deltas into `openspec/specs/`.
- [ ] 9.2 Archive this change.
