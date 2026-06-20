# Windows cold provision hangs: headless units enabled but never started — 2026-06-19

Discovered by `/build-install-and-smoke-test-e2e (windows)` during the
meta-orchestration cycle that re-ran the Windows local-build e2e gate after
Smart App Control was turned off (see
`plan/issues/windows-smart-app-control-build-block-2026-06-18.md`, now resolved).

## Result

Cold WSL2 re-provision reached `Connecting` and then **hung for ~16 minutes**
until the control-wire handshake budget was about to expire. Root cause found,
fixed, and verified in the same cycle.

## Symptom

`tillandsias-tray.exe --provision-once` progressed cleanly through:
`SettingUp → DownloadingRootfs (66 MB) → InstallingTillandsias (OCI flatten +
systemd/podman install, 82 pkgs) → Configuring → StartingVm → ready →
Connecting…` and then stalled. The host control wire never reached Ready.

In-VM diagnosis (`wsl -d tillandsias -u root`) while the host was stuck:

- `systemctl is-active tillandsias-headless-fetch.service tillandsias-headless.service`
  → `inactive` / `inactive`.
- `journalctl -u tillandsias-headless-fetch.service` → `-- No entries --`
  (the units were never even *attempted*).
- `/usr/local/bin/tillandsias-headless` → absent (fetch never ran).
- No vsock listener bound.
- `systemctl status tillandsias-headless-fetch.service` → `Loaded: loaded
  (...; enabled; preset: disabled)`, `Active: inactive (dead)`.
- `systemctl is-system-running` → `running`; `multi-user.target` → `active`;
  `systemctl --failed` → 0 units. So systemd itself was healthy — the units
  were simply enabled-but-not-started.

## Root cause

`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` `inject_bootstrap_logic`
runs **after** `configure_recipe_distro` has flipped `wsl.conf` to
systemd-as-PID1, so by the time the units are written systemd is already up and
`multi-user.target` has already been reached for this boot. The bootstrap then
ran a bare:

```
systemctl enable tillandsias-headless-fetch.service tillandsias-headless.service
```

`systemctl enable` only writes the `WantedBy=multi-user.target` symlinks; it
does **not** start a unit whose target was already active this boot. The very
next provisioning step, `self.runtime.start()` (wsl_lifecycle.rs:218), is a
no-op on an already-running distro — it does not restart it — so nothing ever
triggers the newly-enabled units. The fetch never runs → the in-VM headless
binary is never downloaded → `tillandsias-headless.service` never binds the
vsock control wire → the host loops 36×5s in `Connecting` and fails the
handshake budget.

Intermittency note: the tray log shows prior cold runs that *did* reach Ready
(e.g. 2026-06-18T07:20) because the keepalive / a second `SettingUp` pass
happened to bounce the VM and re-trigger the enabled units; and a 2026-06-14 run
that failed the same way. The bug is a race against whether anything restarts
the distro after enabling, which `--now` removes entirely.

## Causal proof (this cycle)

While the host was hung in `Connecting`, in the VM:

1. `systemctl start tillandsias-headless-fetch.service` → unit `active`;
   journal shows `fetch-headless.sh` curling the binary; `Finished` in ~2s;
   `/usr/local/bin/tillandsias-headless` (39 MB) now present.
2. `systemctl start tillandsias-headless.service` → `active`; emits
   `{"event":"app.started",...}`.
3. The previously-hung `--provision-once` **immediately completed**:
   `[provision] RESULT: VM Ready — control wire up ✓` and the process exited 0.
   Tray log: `VM handshake success (phase=Starting) wire_version=2 attempt=29`
   → `provision-once: VM Ready`.

This proves the substrate is fully healthy end-to-end; the only defect was that
provisioning enabled the units without starting them.

## Fix

- id: `windows/cold-provision-headless-units-not-started`
- type: fix
- owner_host: windows
- capability_tags: [rust, windows, wsl, provisioning]
- status: done (code fixed + fmt/build verified; runtime re-verify recorded in
  the dated smoke report)
- owned_files:
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
- change: `systemctl enable` → `systemctl enable --now` for the two headless
  units in `inject_bootstrap_logic`, so they start in the same provisioning
  session rather than relying on an incidental later restart. Safe on the
  idempotent registered-distro fast path (which skips `inject_bootstrap_logic`
  entirely) and idempotent on re-provision: the fetch unit's
  `ConditionPathExists=!/usr/local/bin/tillandsias-headless` guard makes `--now`
  a no-op once the binary exists, and `tillandsias-headless.service` is
  `Restart`-managed.
- repro (pre-fix):
  1. `wsl --unregister tillandsias`
  2. `tillandsias-tray.exe --provision-once`
  3. observe stall in `Connecting`; in-VM the headless units are
     `inactive (dead)` with empty journals.

## Evidence

`target/build-install-smoke-e2e/20260619T223011Z/`:
`03-provision-once.log` (Connecting stall), `03b-manual-fetch.log`,
`03c-manual-headless.log` (causal proof), `03d-diagnose.json`
(`recent_log_tail` with the handshake-success line).
