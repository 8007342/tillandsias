# Windows tray: control wire never re-establishes after an in-VM headless outage — "Wire unreachable", all menus disabled indefinitely (2026-07-12)

- class: bug (tray resilience / reconnect; order 154 stream domain)
- found by: operator attended smoke (windows-bullo-fable5-20260712T1940Z session)
- status: open
- trace: crates/tillandsias-windows-tray (wire subscription/keepalive reconnect),
  order 154 (reader task + watch channels), tray-parity "status indicator" cell

## Symptom

After the order-310 singleton-kill took the in-VM headless down for ~50s
(14:07:45–14:08:32, systemd auto-restart), the long-running tray (PID 4436,
started 13:11) showed "Wire unreachable" and disabled ALL menus — and stayed
that way for 15+ minutes, while the substrate was fully healthy: distro
Running, unit active, and a fresh `--status-once --json` one-shot from the
SAME installed binary returned `reachable:true, phase:Ready, podman_ready:
true, exit 0`. The tray had survived several earlier restarts/terminates the
same session (probes + menus worked at 13:59–14:07), so some paths reconnect;
this outage pattern (service killed hard mid-subscription, 45s gap) left the
tray's push subscription/keepalive permanently wedged.

## Parity-cell impact

Status-indicator cell evidence: degraded indication works ("Wire
unreachable" shown); RECOVERY does not (never re-arms). The cell cannot be
flipped to done until reconnect works.

## CORRECTION from tray.log (same session, post-quit)

The reconnect DID happen: `21:08:46 INFO vm status push subscription
established (polls suppressed, SC-07)` — 14 seconds after the headless
restart. Yet at ~21:20 the operator saw "Wire unreachable" + ALL menus
disabled, while a one-shot `--status-once` probe returned Ready. So the
defect is (at least primarily) **stale state rendering**: the unreachable
status set during the outage window was never cleared/re-rendered after the
successful re-subscription, and the menu-enable state followed the stale
status. Reframe the fix around status/menu state invalidation on
re-subscribe, with the reconnect loop itself apparently functional on this
evidence.

Also verified in the same log: Quit from the wedged-LOOKING tray worked
(21:22:42 click → graceful drain + `wsl --terminate` backstop → "VM drained
on Quit" at 21:22:53) — quittability (order-288 class) holds on Windows.

## Fix direction

- Reconnect loop with backoff that never gives up while the tray runs
  (re-run the handshake + re-subscribe pushes when hvsocket connects again;
  the one-shot probe path proves connectivity is trivially available).
- Menus: degrade gracefully (status + Quit + Retry stay enabled) instead of
  disabling everything; a disabled Quit on a wedged tray is the order-288
  class.
- Order 154's reader-task/watch-channel refactor is the natural home.

## Repro

Running tray with established push subscription → kill the in-VM headless
hard (the order-310 singleton kill, or `systemctl kill -s KILL` + let
systemd restart it after a stop-timeout) → tray shows Wire unreachable and
never recovers despite the wire being reachable to new connections.
