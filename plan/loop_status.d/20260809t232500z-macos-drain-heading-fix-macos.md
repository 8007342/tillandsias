## Cycle 2026-08-09T16:27Z→23:25Z (macos — operator-directed v0.5 drain, /loop meta-orchestration)

Direction reduced: v0.5 platform readiness + the EXPERTS milestone's macOS
rung (401 tier verdict). Operator: The Tlatoani ("drain all v0.5 macos-only
work"). Selector seed at claim: host-20260809 (selector was BROKEN on macOS
at cycle start — fixed in-cycle, 627-53gu).

## Drained (commits on osx-next, all pushed)

- 606-r42f DONE: dead VzLifecycle/vz_real removed; provision keeps
  idempotency + loud Err; VzGuestConfig deleted (live boot spec pins added);
  cold-provision smoke PASS (seeded qcow2, 2.12s); 151 unit tests green.
- 421 DONE: Gatekeeper hint gated on an actual com.apple.quarantine xattr;
  delta spec + design + proposal amended; property-shaped litmus pin.
- 627-53gu DONE (filed+fixed in-cycle): selector crashed on bash 3.2
  (empty-array set -u), silently required yq, and BSD awk rejected the
  newline -v; ci-release suite 7/7 after. 627-cx24 filed for linux
  (priority never projected → urgency constant 0 fleet-wide).
- 492 DONE: Darwin termios probe PINNED (resets on last-slave-close —
  the 8c6c8d05 retention was load-bearing, audit verifier was right);
  split() drops the bootstrap slave; input-task EOF → wire PtyClose;
  attach client re-raws; host-shell 71/71.
- 628-yd8f DONE (filed+fixed in-cycle, THE find): --capabilities was
  missing from is_cli_mode → an in-guest run singleton-SIGTERMed the live
  vsock server (2026-07-12 --antigravity class). Only macOS/Windows can
  observe it. Fix verified live; retroactively explains the dead 08-03
  order-76 build. All six v0.4.260809.2 images then built to completion
  in-guest for the first time.
- 624-q4jj DONE: all five steps PASS; order-455 macOS smoke for
  v0.4.260809.2 EXPLICITLY DISCHARGED; 635-bhkb filed (--version 0.1.0
  forever). Steady state restored (local build relaunched).
- 598-kibt: M1 GREEN (re-proven on two merged trees), M2 GREEN, M4 GREEN,
  M6 GREEN (first live macOS run of the b13151a1 write path — floods,
  byte-identical 1.29MB input, wedge kill-not-drop 143/SIGTERM, clean
  teardowns), M3 PARTIAL (envelope source live + byte-stable; in-container
  arrival blocked by 635-kagg), M5 operator-gated (zero-repo account).
- 349 BLOCKED on 635-kagg (named blocker event; criteria 1+2 stand).
- 401 PROGRESS: tier:cpu verdict verified live on the guest (criterion 1);
  measurements blocked by 635-kagg for the in-lane half.
- 635-kagg FILED (P1): the tokenless --bash forge lane wedges over the
  exec wire post-vault pre-container, absorbs SIGTERM (3 reproductions:
  3h/45m/45m); exec-wire stdin never delivers EOF (secondary).
- Not claimed: order 155 (blocked on 153, linux in_progress).

## Fleet coordination

Three linux-next integrations merged in-cycle (b42a057d, 48918245→157e41ca,
f4780e2b — the last already round-tripping THIS host's fixes); windows'
632-retq jq guard adopted; two reintroduced GNU grep -P sites in the
rewritten triage litmus fixed same-day. osx-next pushed at every checkpoint;
integration gate (markers/YAML/build-check + stamp) run before every push.

## Metrics

cycle-metrics verdict at close: attention:worktree-dirty (expected — this
close-out commit); experts calls=0 (no expert harness on this host yet);
experts_substitution: unknown (not derivable in-repo). Plan: 627 packets,
224 ready at close.
