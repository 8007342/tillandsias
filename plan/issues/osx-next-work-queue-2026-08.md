# osx-next work queue — 2026-08

One-line outcome rows per cycle (mirrors linux-next-work-queue-2026-05-25.md).
This host is the fleet's only macOS builder.

## Cycle rows

- 2026-08-09T23:25Z  e4792602  606-r42f dead VzLifecycle removed; cold-provision smoke PASS; pins added (Direction: v0.5 readiness under the EXPERTS milestone cycle)
- 2026-08-09T23:25Z  052d3a19  421 Gatekeeper hint quarantine-gated; spec delta amended; litmus pin added
- 2026-08-09T23:25Z  11c509d2  627-53gu batch selector runs on macOS at last (bash-3.2 argv guard, yq→jq, BSD-awk stream); 627-cx24 filed (priority projection gap, linux)
- 2026-08-09T23:25Z  7be4465d  492 PTY bootstrap slave dropped at split(); Darwin probe PINNED (termios resets on last-slave-close — retention was load-bearing); EOF→PtyClose wired; attach client re-raws
- 2026-08-09T23:25Z  493c21b8  628-yd8f --capabilities singleton-killed the live vsock server; one-line is_cli_mode fix + pin; verified live; probable killer of the 08-03 order-76 build
- 2026-08-09T23:25Z  3a8130b6  merge-surfaced cfg(macos) test conflict fixed (order-155 slice-2 test vs M5 loaded-flag semantics)
- 2026-08-09T23:25Z  (frag)    598-kibt: M1/M2/M4/M6 GREEN (M6 first-ever live macOS run of the b13151a1 write path: floods clean, byte-identical input, wedge kill-not-drop 143/15), M3 partial, M5 operator-gated; all six v0.4.260809.2 images built in-guest
- 2026-08-09T23:25Z  (frag)    624-q4jj: ALL FIVE STEPS PASS — order-455 macOS smoke for v0.4.260809.2 explicitly discharged; 635-bhkb filed (tray crate version never synced)
- 2026-08-09T23:25Z  (frag)    635-kagg filed: --bash forge lane wedges over exec wire post-vault (3 reproductions, absorbs SIGTERM) — blocks M3 in-container check, 349 closing run, 401 in-lane measurements
- 2026-08-09T23:25Z  (frag)    349 blocked on 635-kagg (criteria 1+2 still PASS from 07-16); 401 progress: tier:cpu verdict VERIFIED live (exit criterion 1)
- 2026-08-10T05:06Z  (frag)    644-7w89 v0.4.260810.1 curl smoke 5/5 PASS — no regressions vs .2; 421 over-warn GONE in published installer; 635-kagg narrowed (tray lane works, exec-wire-context-specific)
