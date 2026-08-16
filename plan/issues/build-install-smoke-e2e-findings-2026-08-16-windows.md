# Windows local-build destructive e2e — findings 2026-08-16

discovered_by: /build-install-and-smoke-test-e2e (windows), driven by the
meta-orchestration cycle windows-yolanda-fable5-20260816t1021z.
Evidence: `target/build-install-smoke-e2e/20260816T113732Z/` (host-local).

## Run 20260816T113732Z — PASS (commit 781bb6e07, VERSION 0.4.260815.1)

- **Gate 1 build+install+freshness**: build-windows-tray.ps1 exit 0 (2m10s);
  direct-copy install to `%LOCALAPPDATA%\Programs\Tillandsias` (the 2026-07-15
  convention — install-windows.ps1 remains release-download-only and must NOT
  be used here per the never-substitute-a-published-binary guardrail);
  `--version` ran under ENFORCED Smart App Control (no 4551);
  embedded SHA 781bb6e07 == HEAD. Known pre-existing note: guest_wiring
  reported `skipped-version-match` (guest 0.4.260815.1 == tray), so no
  embed-vs-fetch skew this run.
- **Gate 2 destroy**: `wsl --shutdown` + `wsl --unregister tillandsias`; distro
  absent from `wsl --list` after; `tillandsias-build` untouched. Warm-cache run
  (rootfs cache kept, per the 2026-07-15 precedent; truly-cold proven
  2026-07-13). `TILLANDSIAS_DESTRUCTIVE_RESET_OK` unset.
- **Gate 3 cold provision**: attempt 1 imported + dnf-configured the distro and
  reached `VM ready — control wire established` at 11:42:07Z (~2 min
  configure→Ready) — then STAYED RESIDENT (see finding below) until the
  harness's 600s cap killed the process post-Ready. Retry (idempotency
  exercise) reached Ready again at 11:52:33Z and exited 0 once released.
  **Post-condition after the last mutating step**: fresh `--diagnose --json`
  exit **0** — distro registered+running, wire reachable, phase Ready,
  podman_ready true, no error.
- **Gate 4 forge lane**: n/a (linux-only lane per skill).

## Finding: `--provision` no longer exits at Ready — it stays resident holding the control wire

2026-07-15's run ended with `RESULT: VM Ready — control wire up ✓` and exit.
The current build reaches Ready, then logs `VM keepalive holding the control
wire warm` + `vm status push subscription established (polls suppressed,
SC-07)` and keeps running with stdout unflushed. An unattended caller that
waits on process exit therefore reads a healthy provision as a hang: this run
burned 10 minutes and one kill on exactly that misread, and only the tray log
revealed Ready had been reached 8 minutes earlier.

If resident-after-Ready is the intended SC-07 design, `--provision` should
say so on stdout at Ready (a flushed, greppable `RESULT: VM Ready` line
BEFORE going resident, or a `--provision --exit-on-ready` mode for
automation). If it is not intended, the keepalive path should not be entered
from the one-shot provision entrypoint. Either way the current shape makes
every scripted provision wait unbounded. Class: unattended-automation
contract; same family as the MO-FULL "a marker nothing parses" rule — a
completion signal that only a human tailing a log can see is not a signal.

## Residuals

- 599-3b9h remaining criteria stay attended-only (menu UX, PTY attach, icon
  rendering); this PASS is explicitly NOT release acceptance for the
  interaction surface.
- 769-w3ma real-lane launch remains attended-only, unchanged by this run.
