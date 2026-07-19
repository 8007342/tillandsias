# Guest crash-loop DETECTION + one-click intentional EPHEMERAL RESET (runtime resilience)

- Date: 2026-07-17
- Source: operator (The Tlatoāni) directive after a live runtime crash-loop
  on the Windows host (windows-260717-2 vault-unseal regeneration cascaded
  into a headless/tray restart loop that flashed terminal windows)
- Release target: stable-milestone-v1
- Related: `vault-unseal-secret-regenerated-on-reensure-2026-07-17.md`
  (windows-260717-2, the concrete trigger), order 383 (vault self-heal /
  OPERATOR ACTION REQUIRED verdict), order 279 (host-lifecycle race
  safeguards), order 385 (tray terminal reaping), the tray `--diagnose`
  surface, and the ephemeral/cloud philosophy (methodology).

## The problem, stated by the operator

"Is this something that could happen to end users at runtime, even during
updates/crashes/restarts?" — YES. windows-260717-2 triggers on any cold
start of the guest (app update that restarts the VM, host reboot, crash, or
a Quit+relaunch). The failure is a self-sustaining loop: vault can't unseal
→ headless can't finish bootstrap → headless restarts → tray re-pokes WSL →
terminal windows flash and vanish → repeat. From the user's seat it looks
like the app is broken with no obvious recourse.

## The operator's design decision (ephemeral all the way)

"Since Tillandsias is all about being ephemeral, the worst case scenario is
the user will have to re-authenticate, and it all lives in the cloud. No
harm done. Ephemeral all the way, the Tillandsias way. Do rebuild and
reprovision from scratch as needed, destructive ok."

So the guest (and its vault) is DISPOSABLE by design. Recovery is a
first-class, safe, expected operation — not a last resort. State of value
lives in the cloud + the operator's auth; a reset costs a re-login.

## What to build (two capabilities)

### 1. Crash-loop DETECTION (surfaced, falsifiable)

The host tier must be able to tell that the guest is looping instead of
converging, and say so — quietly to itself (to trigger auto-recovery) and
visibly to the user (tray state + `--diagnose`).

- A bounded restart/bring-up counter with a time window: N headless
  app.stopped→started cycles, or M vault unseal failures, or K wire
  handshake timeouts within T seconds ⇒ verdict `crash-loop:<subsystem>`.
- Distinguish LOOP from a slow-but-progressing bring-up (provision phases
  advancing = not a loop) so we never reset healthy-but-slow starts.
- Emit a pinned grammar (like the credential/tier probes):
  `^(healthy|starting|crash-loop:[a-z0-9-]+)$` from `--diagnose` and a
  matching tray status line (order 250 ultra-minimal tray UX: the single
  most-important notification — "guest is crash-looping, click to reset").
- The signal is the trigger for both auto-recovery backoff and the manual
  reset affordance below.

### 2. Intentional EPHEMERAL RESET (one action, destructive-by-design)

A user-invokable (and, where safe, auto-invokable) "reset the guest" that
wipes and reprovisions from scratch — the exact recovery done by hand this
cycle (`wsl --unregister <distro>` + tray reprovision on Windows; the VZ/
podman equivalents on macOS/Linux), but as a supported, one-click path.

- Tray menu item + `--reset-guest` CLI verb: terminate, unregister/destroy
  the guest, reprovision fresh, re-establish the wire. Fresh first-provision
  initializes vault cleanly (the windows-260717-2 regeneration bug bites
  only on re-ensure, never on first init), so a reset always yields a
  working vault.
- Clear, honest UX: "This discards the local guest and its cached
  credentials. Everything lives in the cloud — you'll re-authenticate once.
  Continue?" No scare, no data-loss ambiguity — it's the designed model.
- Auto-recovery ladder: on a detected crash-loop, the host may attempt a
  bounded self-reset (backoff, capped attempts) and, if still looping,
  surface the manual reset with the diagnosis. Never an unbounded auto-loop
  (that is the very failure we are fixing).

## Relationship to the underlying bug

windows-260717-2 (make re-ensure reuse the matching unseal key / fail loud
once instead of regenerating) is the ROOT fix that stops the loop from
starting. This packet is the RESILIENCE layer that makes the *class* of
runtime wedge (any subsystem, any cause) detectable and one-click
recoverable — so even a future unforeseen wedge degrades to "reset and
re-auth," never to "flashing terminals with no recourse." Both land under
stable-milestone-v1.

## Verifiable closures

- Detection: a fixture/litmus drives N stop→start cycles (or seals the
  vault key) and asserts `--diagnose` flips to `crash-loop:<subsystem>`
  within the window, and does NOT flip during a normal (progressing)
  provision.
- Reset: an e2e that, from a deliberately-wedged guest, invokes the reset
  path and reaches VM Ready + healthy vault + wire Reachable with no manual
  steps; a subsequent auth restores cloud project listing.
