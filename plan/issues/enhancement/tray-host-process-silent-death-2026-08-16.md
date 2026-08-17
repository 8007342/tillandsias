# Windows tray process died silently on the host — no crash surface, no restart, no diagnostic trail

- classification: enhancement
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: open
- packet: 783-eeii (ready, kind=fix, pickup_role=windows, desired_release=v0.5)
- cross-ref: 594-u6zy (guest-crashloop-detection, completed) — this is the
  HOST-side analog gap
- cross-ref: plan/issues/enhancement/wsl-guest-vm-unpinned-when-tray-down-2026-08-16.md
  — the tray's vsock session is the runtime guest's ACCIDENTAL VM pin, so a
  silent tray death also drops the guest (confirmed by death 2 below)

## Observation 1 — death between ~05:00 and 13:27 local

The tray process died silently on this host sometime between ~05:00 local
(post-e2e relaunch, cycle 4) and 13:27 local, when the operator found no
tray icon and the process absent. A manual relaunch succeeded immediately:
PID 8768, StartTime 16/08/2026 13:27:33.

- No crash surface: nothing on screen, no error dialog.
- No restart: nothing supervises the host tray process.
- No diagnostic trail found yet: no log line, dump, or event record has
  been located that explains the death — up to eight and a half hours of
  absence was discovered only by a human noticing a missing icon.

## Observation 2 — SECOND death the same day, between ~14:05 and 23:08 local

The relaunched process (PID 8768, started 13:27:33) was confirmed running
through the attended lane work at ~14:05 local. At 23:08 local
(2026-08-17T06:08Z — this host is UTC-7, so all clock times in this file
are local and the second death crosses the UTC date line) `Get-Process
tillandsias-tray` returns nothing.

- Same signature as death 1: no crash dialog, no restart, no operator
  action in between — the process is simply gone.
- NEW: the blast radius is now observed. The `tillandsias` runtime distro
  is `State=Stopped`, and the enclave went down with it — vault, proxy,
  router and git-java are all gone. This is the unpinned-guest mechanism
  (see cross-ref) firing as a consequence of the tray death: losing the
  tray does not just remove the GUI surface, it tears down the whole
  runtime substrate.

Two unexplained host-process deaths in one day on this host, both
undetected until a human looked. Whatever kills it is recurrent, not a
one-off.

## Why this matters

594-u6zy built crashloop detection for the GUEST; the host tray has no
analog. A silently dead tray removes the only lane-launch and login surface
on Windows while looking exactly like "the user closed it".

After death 2 this is no longer only a GUI-availability gap: an unattended
host whose tray dies silently cannot run lanes AT ALL — the guest stops with
it and the enclave goes with the guest. There is no human watching for a
missing icon on an unattended host, so the failure is both silent and total.
That is what makes it v0.5 work rather than an observability nicety.

## Open questions

- Where did the process go? (exit? kill? crash? OS teardown?) Windows Event
  Log / WER were not yet searched — that is the first diagnostic step.
  Two death windows are now available to search: ~05:00-13:27 and
  ~14:05-23:08 local on 2026-08-16 (PID 8768 for the second).
- Does the tray have any exit-path logging today, and did it fire?
- Is the recurrence periodic? Both deaths bracket a multi-hour idle stretch,
  which is consistent with an OS-side teardown of an idle process rather
  than a workload-triggered crash — worth testing before assuming a bug in
  tray code.

## Smallest next action

Establish the diagnostic trail first: check Windows Event Log/WER for the
PID around the two death windows above, and add tray exit-path logging
(reason + timestamp) so the NEXT silent death leaves a trace. Detection/
supervision (the host-side analog of 594-u6zy) can be scoped once a death is
attributable. Tracked as packet 783-eeii.
