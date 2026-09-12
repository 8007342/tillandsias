# The tray's wedged-VM recovery runs a GLOBAL `wsl --shutdown`, killing every other distro on the host — the product violating 802-bajv from the inside

**Filed:** 2026-09-12 · **Kind:** bug · **Capability tags:** windows, tray, recovery, multi-host
**Host:** ESMERALDINHA (Windows 11 + WSL2), observed during the v56.9.12.1 smoke

trace: plan/issues/smoke-e2e-findings-v56.9.12.1-2026-09-12.md
       order 802-bajv (terminate, not shutdown — written for the runbook)

## Claim

When the control wire does not come up on a fresh VM start, the tray's recovery
path runs **`wsl --shutdown`**, which stops **every WSL2 distro on the host**,
not just its own. Measured from the tray's own log:

```
04:08:28 ERROR control wire never came up on a fresh VM start — running one
         bounded WSL shutdown recovery so the wedged VM does not linger
04:08:28  WARN WSL service appears wedged. Attempting recovery via wsl --shutdown...
04:08:34  INFO wsl --shutdown completed successfully
04:08:36  INFO bounded WSL shutdown recovery completed after a wedged fresh start
```

Observed effect: `tillandsias-build` went from Running to Stopped. It is an
unrelated distro that the tray has no business touching.

## Why this matters beyond one stopped distro

Order 802-bajv exists precisely because of this hazard, and says so in the
smoke runbook's own words: `--shutdown` "stops EVERY WSL2 distro on the host,
while `--unregister` only requires the target distro to be stopped. A Windows
host commonly also runs `tillandsias-build` — the lane that builds
Linux-target artifacts, kept deliberately separate so the smoke cannot wipe a
toolchain mid-cycle."

The runbook was disciplined into `--terminate` for exactly this reason. **The
product itself was not.** On this host `tillandsias-build` is where
`./build.sh --check` runs, so a tray recovery firing during a land gate would
kill an in-flight gate — a ~25 minute floor-tier build — with no relationship
to the tray's own fault.

That is not hypothetical here: this host runs gates and the tray on the same
box, and the recovery fired while the machine was mid-cycle.

## Measured

- Before provision: `tillandsias-build` Running (it had just been used for a land gate)
- Tray recovery ran `wsl --shutdown` at 04:08:34Z
- After: `tillandsias-build` Stopped

The recovery is described in the log as "bounded", and it is — it runs once.
Bounded in count is not the same as bounded in blast radius.

## Exit criteria

- "the tray's wedged-VM recovery affects only its own distro; pre-fix result: FAILS (`wsl --shutdown` stopped tillandsias-build, an unrelated distro)"
- "a gate running in another distro survives a tray recovery on the same host; pre-fix result: FAILS by the same mechanism"
- "NEGATIVE CONTROL: the recovery still clears a genuinely wedged tillandsias VM — the fix is to narrow the blast radius (`wsl --terminate tillandsias`), not to remove the recovery"

## Shape of the fix

`wsl --terminate tillandsias` accomplishes the stated goal ("so the wedged VM
does not linger") without touching other distros. If a global shutdown is ever
genuinely required, it should be gated behind an explicit opt-in and should say
in the log which other distros it is about to stop.

## Note on discovery

Found only because this host happened to have a second distro running and I
checked its state after an unrelated failure. On a single-distro host this is
invisible. Worth asking whether any past Windows result was affected by a
recovery nobody noticed.
