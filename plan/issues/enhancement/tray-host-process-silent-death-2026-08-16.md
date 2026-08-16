# Windows tray process died silently on the host — no crash surface, no restart, no diagnostic trail

- classification: enhancement
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: open
- cross-ref: 594-u6zy (guest-crashloop-detection, completed) — this is the
  HOST-side analog gap

## Observation

The tray process died silently on this host sometime between ~05:00 local
(post-e2e relaunch, cycle 4) and 13:27 local, when the operator found no
tray icon and the process absent. A manual relaunch succeeded immediately:
PID 8768, StartTime 16/08/2026 13:27:33.

- No crash surface: nothing on screen, no error dialog.
- No restart: nothing supervises the host tray process.
- No diagnostic trail found yet: no log line, dump, or event record has
  been located that explains the death — up to eight and a half hours of
  absence was discovered only by a human noticing a missing icon.

## Why this matters

594-u6zy built crashloop detection for the GUEST; the host tray has no
analog. A silently dead tray removes the only lane-launch and login surface
on Windows while looking exactly like "the user closed it".

## Open questions

- Where did the process go? (exit? kill? crash? OS teardown?) Windows Event
  Log / WER were not yet searched — that is the first diagnostic step.
- Does the tray have any exit-path logging today, and did it fire?

## Smallest next action

Establish the diagnostic trail first: check Windows Event Log/WER for the
PID around the death window, and add tray exit-path logging (reason +
timestamp) so the NEXT silent death leaves a trace. Detection/supervision
(the host-side analog of 594-u6zy) can be scoped once a death is
attributable.
