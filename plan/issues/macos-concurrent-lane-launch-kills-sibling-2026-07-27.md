# Concurrent lane launch tears the shared stack from under a live sibling — both lanes die (macOS attended, order-491 session)

- **Date:** 2026-07-27
- **Class:** bug (P1 — multi-lane concurrency; v0.4 blocker candidate)
- **Area:** guest tillandsias-headless launch pipeline (shared-stack refcount,
  order 443 slice 3) — NOT the terminal-attach@v2 chain (guest vsock server
  spawns one handler per accept, vsock_server.rs:564; connection preemption
  ruled out).
- **discovered_by:** operator attended session (macOS, tray 5d29a1c2):
  relaunched OpenCode lane ("opened fine"), then launched a Maintenance
  lane — the new window took focus and BOTH lanes died.
- **Specs:** tray-concurrency, order-443 shared-stack refcount
  (cleanup_shared_stack_if_no_running_forge, main.rs:4459-4541)

## Hard evidence (host-side Terminal.app scrollback recovery)

- The second lane's window printed, at session start:
  `[tillandsias] no active lane containers; cleaning project + shared stack
  for tillandsias` — the order-443 guard read ZERO active lanes + ZERO
  foreign launch flocks while the sibling OpenCode lane was mid-bring-up.
- The OpenCode lane's window shows death by yanked dependency:
  `Cloning into '/home/forge/src/tillandsias'...` then
  `fatal: unable to connect to tillandsias-git ... Connection refused`.
- The git service IP DIFFERS between windows (`tillandsias-git[0:
  10.0.42.14]` vs `10.0.42.20]`) — the shared stack was torn down and
  recreated across the incident. Teardown-under-sibling is proven; only the
  guard-miss mechanism is undetermined.
- Also observed in the Maintenance window: inference exec on a non-running
  container ("can only create exec sessions on running containers …
  tillandsias-inference", tolerated), and a Homebrew ncurses bottle
  attestation failure (separate noise; possibly why Maintenance itself
  died after killing its sibling).

## Why the guard SHOULD have held (and what to check in-guest)

`cleanup_shared_stack_if_no_running_forge` refuses teardown when (a) any
`tillandsias-*` container matching `is_active_lane_container` (alive OR
starting states, main.rs:4438-4457) exists, or (b) a foreign
launch-in-flight flock is held (acquired at main.rs:6424 and held for the
launch's duration). The clone runs INSIDE the forge container's entrypoint
(clone_project_from_mirror), so at clone time the sibling had a RUNNING
`-forge` container AND a held flock — yet the second lane read both as
zero. Hypotheses, in-guest checks for each (idiomatic layers only):

1. **flock visibility**: are markers per-boot / per-tmpdir such that two
   PTY-lane child processes don't share the marker directory? Check the
   marker dir contents while two lanes run; confirm
   `foreign_launches_in_flight` lists the sibling from the second process.
2. **ps visibility race**: `podman events --since <window>` timeline — was
   the sibling forge container in a state string the predicate excludes, or
   genuinely absent at scan time (podman run still pulling)? If the flock
   is held for the whole launch (it should be), this alone cannot explain
   the miss — which makes hypothesis 1 primary.
3. **cleanup-then-ensure semantics**: even a correct "last one out" verdict
   must not break a MID-CLONE sibling — confirm whether the second lane's
   `ensure` recreated git with a new IP while the first lane's clone TCP
   connection was live (evidence says yes). Any fix must make the guard
   sufficient BEFORE teardown, not rely on recreate-quickly.

## Repro

macOS tray: launch OpenCode lane on project P; while it is still in
bring-up (cloning), launch Maintenance on P. Observed: second lane logs
"no active lane containers; cleaning…", first lane dies with git
Connection refused. Deterministic in the 2026-07-27 attended session.

## Non-goals / notes

- Terminal focus moving to the new window is Terminal.app `activate` —
  cosmetic, expected, unrelated to the deaths.
- The order-491 terminal-attach verification is NOT blocked: single-lane
  probes proceed; multi-lane launches should be avoided until this closes.
