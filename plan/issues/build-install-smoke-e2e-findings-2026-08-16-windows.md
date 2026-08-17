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
  configure→Ready) — then STAYED RESIDENT (see finding below; the ORIGINAL
  explanation for that residency is **refuted** — read the correction) until
  the harness's 600s cap killed the process post-Ready. Retry (idempotency
  exercise) reached Ready again at 11:52:33Z and exited 0 once released.
  **Post-condition after the last mutating step**: fresh `--diagnose --json`
  exit **0** — distro registered+running, wire reachable, phase Ready,
  podman_ready true, no error.
- **Gate 4 forge lane**: n/a (linux-only lane per skill).

## Finding (ORIGINAL, 2026-08-16 — retained verbatim; **REFUTED**, see the correction below)

> ### `--provision` no longer exits at Ready — it stays resident holding the control wire
>
> 2026-07-15's run ended with `RESULT: VM Ready — control wire up ✓` and exit.
> The current build reaches Ready, then logs `VM keepalive holding the control
> wire warm` + `vm status push subscription established (polls suppressed,
> SC-07)` and keeps running with stdout unflushed. An unattended caller that
> waits on process exit therefore reads a healthy provision as a hang: this run
> burned 10 minutes and one kill on exactly that misread, and only the tray log
> revealed Ready had been reached 8 minutes earlier.
>
> If resident-after-Ready is the intended SC-07 design, `--provision` should
> say so on stdout at Ready (a flushed, greppable `RESULT: VM Ready` line
> BEFORE going resident, or a `--provision --exit-on-ready` mode for
> automation). If it is not intended, the keepalive path should not be entered
> from the one-shot provision entrypoint. Either way the current shape makes
> every scripted provision wait unbounded. Class: unattended-automation
> contract; same family as the MO-FULL "a marker nothing parses" rule — a
> completion signal that only a human tailing a log can see is not a signal.

## Correction 2026-08-17: this run never invoked `--provision-once`. The real defect is that the tray had no unknown-flag refusal.

corrected_by: windows-opus5-subtractive-20260817 (yolanda), from the
2026-08-17 architecture audit. The observation above (the run hung; 10 minutes
and one kill were burned; Ready had been reached 8 minutes earlier) is
ACCURATE. Its **explanation** is not, and the refuting evidence was already
sitting in this finding's own evidence directory.

**The flag was `--provision`. The binary's mode is `--provision-once`.**
`crates/tillandsias-windows-tray/src/main.rs` dispatched `--help/-h`,
`--version/-V`, `--provision-once`, `--reset-guest`, `--status-once`,
`--diagnose`, `--logs` — and then **fell through to the GUI tray** for
anything else. `--provision` matched no arm, so the smoke launched a GUI tray,
which provisioned as a side effect of starting up and then, correctly, went
resident. Nothing about SC-07 or the keepalive is implicated.

**Evidence, in this run's own directory** (`target/build-install-smoke-e2e/20260816T113732Z/`):

| check | value |
|---|---|
| `03-provision.log` line count | 528 |
| lines matching `[provision]` | **0** |
| lines matching `RESULT` | **0** |
| first line of the log | `Failed to set locale, defaulting to "C.UTF-8"` — dnf output from the child `wsl.exe` |

`provision_once()` (`notify_icon.rs:832`) prints
`[provision] starting recipe provisioning…` as its **first** statement and
routes every phase through a `ConsoleProgress` that prefixes `[provision] `.
A log with 528 lines and zero `[provision]` prefixes is proof that
`provision_once()` never ran. The 528 lines are the GUI tray's child `wsl.exe`
dnf output inherited on the console.

**Do not open an SC-07 design review.** The question "is
resident-after-Ready the intended SC-07 design?" is not raised by this run,
because this run never entered the one-shot provision entrypoint. Asking it
sends the next investigator to the wrong subsystem — which is why this
correction exists rather than a silent edit.

**The real defect, and its history.** Windows had no strict-unknown-flag
policy. macOS has had one since `crates/tillandsias-macos-tray/src/main.rs`
(the `find(|a| a.starts_with('-'))` refusal, exit 2), and
`plan/archive/build-install-smoke-e2e-findings-2026-06-14.md` already
prescribed exactly this policy for both trays. macOS implemented it; Windows
never did. Fixed 2026-08-17 on windows-next: an unrecognized `--flag` now
prints a usage error to stderr and exits 2 instead of launching the GUI tray.

**A separate, still-open defect that must not be merged into this one.** The
Windows connect path *is* independently unbounded and uncancellable —
`SO_SNDTIMEO` does not bound `connect()` on Winsock, the connect runs in an
uncancellable `spawn_blocking`, and `hcsdiag list` has no timeout, so
`Runtime::drop` can block after the last line prints. That is a real hang
shape and it is filed as **795-tb4a**. It is *not* what happened in this run.
Both are real; only the flag fall-through explains this log.

Filed packets: **795-tb4a** (the connect path). The unknown-flag refusal
itself landed rather than being filed.

## Residuals

- 599-3b9h remaining criteria stay attended-only (menu UX, PTY attach, icon
  rendering); this PASS is explicitly NOT release acceptance for the
  interaction surface.
- 769-w3ma real-lane launch remains attended-only, unchanged by this run.
