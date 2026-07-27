# P2: macOS forge CPU runaway — VM pegged at 400% (all vCPUs), terminal unresponsive

- **Date:** 2026-07-24
- **Class:** bug — performance pathology (CPU runaway / liveness)
- **Area:** macOS VZ forge runtime — guest CPU saturation → PTY/terminal starvation
- **Severity:** P2 — the forge becomes unusable (terminal unresponsive, 4 host cores burned) until force-terminated. Opposite of the near-zero-overhead target.
- **Discovered by:** operator report ("BigPickle's terminal has become unresponsive") during a live attended OpenCode forge session, confirmed by host-side measurement.

## Symptom (measured)

The VZ VM process (`com.apple.Virtualization.VirtualMachine.xpc`, pid 68612) was **pegged at ~400% CPU** — all 4 vCPUs maxed (`vz.rs:981` clamps to 4), `STAT = Rs`, sustained across every sample (370–401%). The overall 10-core Mac dropped from ~88% idle to ~57% idle. The guest was CPU-saturated, so it could not service the Terminal.app→screen→vsock→PTY chain → the terminal went unresponsive. **SIGKILL of the VM recovered the host to 94% idle immediately**, confirming the VM was the entire spin.

This is NOT idle-stuck (which would read ~0%); it is a runaway busy-loop inside the guest/forge.

## Timing + hypotheses

The hang occurred as BigPickle **was about to push** — into the known-broken macOS push route (`macos-forge-no-push-route-lane-decision-2026-07-23.md`: origin is the offline `github.com` URL with no reachable route). Ranked hypotheses:

1. **Push-retry spin (most likely, and testable):** `git push` (or the harness's git wrapper) hit the unreachable origin and entered a tight retry / DNS-re-resolution / connection-retry loop. If so, the **push-route fix (`35635836`) should also resolve this runaway** — the push succeeds via the mirror instead of spin-failing. **Verification: after deploying the fix, watch for recurrence at push time.**
2. **Poll/probe busy-loop:** an idiomatic-layer probe or readiness poll spinning without backoff — the exact class the "we don't like polling, EVER" mandate + `research-impl-rate-limiting-expensive-probes-2026-07-23.md` warn about.
3. **Harness (OpenCode) internal busy-loop** unrelated to push.

The guest-internal culprit could not be captured live: exec'ing into a CPU-pegged VM is unreliable, and `--exec-guest` against a live VM risks a second-VM disk conflict.

## Impact

A single runaway saturates the guest and starves the control/PTY plane — the operator loses the terminal and must force-terminate. On battery/thermals it is worse. This is a liveness + efficiency defect and undermines the "macOS:virtualization is as efficient as Linux/WSL2" goal (`macos-vz-vm-overhead-measurement-2026-07-24.md`).

## Next actions

1. **Deploy the push-route fix + relaunch**, then reproduce a push and watch the VM CPU — if the runaway is gone, hypothesis 1 is confirmed and this is closed-by `35635836`.
2. If it recurs independent of push: add a **guest-side CPU sampler** (safe, on a VM this cycle owns) to identify the spinning PID (harness vs a forge-stack container vs a poll loop), then fix at the source with backoff / single-flight.
3. Consider a **guest CPU-runaway guard**: if the guest sustains ~100%/vCPU for N seconds while the control plane is idle, surface it on the control wire (a `blocked{runaway}` state) rather than silently starving the PTY.

## Cross-references

- `plan/issues/macos-forge-no-push-route-lane-decision-2026-07-23.md` + `macos-forge-push-route-slice1-implemented-2026-07-23.md` — the push route whose failure is the leading suspect.
- `plan/issues/macos-vz-vm-overhead-measurement-2026-07-24.md` — the overhead measurement this contradicts (efficient at rest, pathological here).
- `plan/issues/research-impl-rate-limiting-expensive-probes-2026-07-23.md` — the poll/backoff discipline (hypothesis 2).
