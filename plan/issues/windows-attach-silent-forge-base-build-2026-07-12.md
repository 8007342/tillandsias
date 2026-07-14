# Windows attach UX: multi-minute on-demand forge-base build is silent in the lane terminal (2026-07-12)

- class: enhancement (attach UX, first-run)
- found by: operator attended smoke (windows-bullo-fable5-20260712T1940Z session)
- status: open
- trace: lane launch path (order 298 cleanup-before-ensure), Windows
  wsl.exe console<->in-VM PTY bridge

## Symptom

First agent/terminal attach on a fresh substrate triggers the on-demand
forge-base image build (558 packages, several minutes). On Windows the lane
terminal prints `[tillandsias] no active lane containers; cleaning project +
shared stack for <project>` and then NOTHING until the build completes — the
operator read it as a hang (reported live 2026-07-12). Guest-side the build
was running fine (`podman build -t localhost/tillandsias-forge-base:v0.3.260712.1
--http-proxy=false --dns 8.8.8.8` visible in /proc).

On macOS the order-294 session saw the package downloads streaming in the
PTY tee, so the information exists in the build output; the Windows bridge
(or this launch phase) does not surface it.

## Fix direction

Stream (or summarize with a heartbeat, e.g. "building forge-base image:
step N/M…") the on-demand image build progress into the lane terminal on
the wsl.exe bridge path, mirroring what the macOS PTY path shows. At
minimum print one line when the build STARTS ("building forge-base image —
first run takes several minutes") so silence has a stated cause.

## Repro

Fresh substrate (no forge-base image) → attach any lane from the tray →
observe the cleanup line then silence for the build duration.

## macOS parity evidence (2026-07-12 attended smoke) — NOT Windows-only

The macOS maintenance lane on a pristine substrate (osx-next `374cb0b8`)
shows the SAME near-silence: `[tillandsias] no active lane containers;
cleaning project + shared stack for tillandsias` at 15:19, the `[forge]`
git-mirror banner around 15:25, interactive prompt ~15:27 — two lines of
output across ~8 minutes of first-run bring-up. This contradicts the earlier
"macOS PTY tee streams the build output" observation above (order-294
session), at least for the shared-stack/ensure phase on this path. Treat the
heartbeat/progress fix as cross-platform, not a wsl.exe-bridge special case.
The operator read the silence as a hang live on BOTH platforms — two
independent reproductions of the same UX conclusion.
