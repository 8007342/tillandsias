# `wsl --terminate` is not a cold boot for anything living in the kernel

**Date:** 2026-08-17
**Host:** windows (yolanda)
**Classification:** research/
**Order:** 800-7jbs
**Found while:** verifying 798-emje

## The measurement

Three "cold boots" run as `wsl --terminate tillandsias` + `wsl -d tillandsias`
all reported `vsock_loopback before=loaded`. The adverse test then **deleted**
`/etc/modules-load.d/tillandsias-vsock.conf` and terminated again — and the
module was **still** `before=loaded`.

That is impossible if the boot were cold. Every WSL2 distro shares **one utility
VM and one kernel**. `--terminate` kills the distro's PID 1 and its namespaces;
a module loaded by an earlier boot stays resident. Only `wsl --shutdown` tears
the VM down.

The monotonic clock settles it:

| after | `ExecMainExitTimestampMonotonic` of `systemd-modules-load` |
|---|---|
| `wsl --terminate` | 85,806,268,214 µs (~23.8 h — the VM's uptime) |
| `wsl --shutdown`  | 1,853,311 µs (~1.8 s) |

Re-run under `--shutdown`, the adverse boot immediately produced the expected
`before=missing after=loaded`.

## Why this is a class, not an anecdote

It is the same shape as the already-recorded trap that **`journalctl -b` in WSL2
does not mean "this boot"** — the boot id does not rotate across
terminate/start, so `-b` silently returns the *original* boot.

Both members: a WSL command that looks like a reboot, reads like a reboot in the
docs, and resets strictly *less* than a reboot. The verifier gets a green result
from a run that never exercised the thing under test. The `journalctl` half was
written down and was in this cycle's operator brief; the terminate/shutdown half
was not, and cost a wasted adverse run **in the same cycle that was carrying the
warning about its sibling**.

## The distinction worth writing down

- **distro-cold** (`wsl --terminate <distro>`) — resets: PID 1, units,
  namespaces, `/run`, in-distro process state. Does **not** reset: kernel
  modules, the boot id, the monotonic clock, other distros.
- **kernel-cold** (`wsl --shutdown`) — resets the utility VM, hence all of the
  above. It stops **every** distro on the host, so it is a coordination event
  and not a free reset: a sibling agent's build distro goes down with it.

Pick by what the property under test lives in. Module residency, boot id, and
anything read from `/proc` or `/sys` at kernel scope need kernel-cold.

## Cost if unfixed

A verifier reaches for `--terminate` because it is the polite, scoped one, gets
a pass, and reports "N cold boots, N passes" for a property that was never
re-exercised. That is worse than no evidence: it reads as proof and carries
none — the same failure mode as an unverified attestation (651-2x5s).

## Postscript, unrelated, small, and it cost a round trip

`scripts/check-windows-only-sources-verified.sh stamp` refuses with:

```
refused:stamp-needs-evidence:pass --from <cargo-test-output>; ...
```

The intended reading is "*pass* `--from <file>`" (an instruction), but it parses
naturally as the literal argument list `stamp pass --from <file>` — which the
script then refuses again, identically, because `$2` must be `--from`. The
correct call is `stamp --from <file>`. Refusal text that a reader can obey
verbatim and still be refused is a small fail-loud defect in a gate whose whole
purpose is to be obeyed; the fix is one word (`use: --from <cargo-test-output>`).

