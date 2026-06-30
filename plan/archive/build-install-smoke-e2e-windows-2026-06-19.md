# Build-Install Smoke E2E (Windows) — 2026-06-19

Discovered by `/build-install-and-smoke-test-e2e (windows)`, run as the E2E gate
of a Windows meta-orchestration cycle after the operator turned Smart App
Control **off** (unblocking native builds — see
`plan/issues/windows-smart-app-control-build-block-2026-06-18.md`, now resolved).

- host_kind: windows
- branch: `windows-next`
- commit tested: `1dfd2bea` (+ in-cycle fix, see below)
- installed version: `tillandsias-tray 0.3.260619.2 (1dfd2bea)`
- VERSION: `0.3.260619.2`
- evidence dirs: `target/build-install-smoke-e2e/20260619T223011Z/` (initial run)
  and `target/build-install-smoke-e2e/<RUN2>-fixverify/` (post-fix re-run)

## Result: PASS (with one defect found, fixed, and re-verified this cycle)

| Gate | Result |
|------|--------|
| SAC unblock check (`cargo check -p tillandsias-policy`) | PASS — serde build-script ran, finished 6.46s, no os error 4551 |
| Build (`build-windows-tray.ps1`, release) | PASS — `tillandsias-tray.exe`, exit 0, 57s |
| Install (`install-windows.ps1`) + freshness | PASS — installed `--version` git SHA == HEAD `1dfd2bea` |
| Destroy substrate (`wsl --unregister tillandsias`) | PASS — distro + VHDX gone, `still_registered=False` |
| Cold re-provision (`--provision-once`) | PASS — `RESULT: VM Ready — control wire up ✓` (auto, after fix) |
| Forge lane | N/A — Linux/Podman-only per skill |

## Defect found and fixed in-cycle

Cold `--provision-once` initially **hung ~16 min in `Connecting`**: the in-VM
`tillandsias-headless-fetch`/`tillandsias-headless` units were `enabled` but
never started (empty journals, headless binary never fetched, no vsock
listener). Root cause: `wsl_lifecycle.rs::inject_bootstrap_logic` ran
`systemctl enable` (not `--now`) after systemd had already reached
`multi-user.target` this boot, and the following `runtime.start()` is a no-op on
an already-running distro — so nothing started the units.

Fix: `systemctl enable` → `systemctl enable --now` for the two headless units.
fmt clean, release build clean.

Full root-cause + causal proof:
`plan/issues/windows-cold-provision-headless-units-not-started-2026-06-19.md`.

## Post-fix re-verification (gold standard)

Rebuilt + reinstalled the fixed tray, `wsl --unregister tillandsias` again, then
cold `--provision-once` with **no manual intervention**:

- `[provision] RESULT: VM Ready — control wire up ✓`, process exited 0.
- In-VM: `tillandsias-headless.service` came up `active` on its own; binary
  fetched (39 MB, oneshot fetch unit ran then went inactive as designed);
  `{"event":"app.started",...}` at 18:00:23.
- Host `--status-once --json`: `reachable: true, wire_version: 2,
  phase: Starting` (exit 2 = reachable, podman still warming) — control wire
  confirmed up.

## Notes / scope

- This gate validates build + install + destroy + cold re-provision + control
  wire. Per the skill it does **not** exercise the live tray menu UX, PTY
  attach, project enumeration, or icon rendering — those need a user-attended
  click-smoke and are not release acceptance on their own.
- Benign pre-existing WSL warning observed in both runs:
  `wsl: Failed to start the systemd user session for 'root'` — unrelated to the
  headless units; not filed.
- WSL on-demand behavior: the distro auto-stops after `--provision-once` exits,
  so a later `--diagnose` reports `exit 2` (degraded: registered, not running).
  Expected, not a finding.
