# v0.4.260815.1 promotion hold: re-read it against 798-emje, not 795-jeym

**Date:** 2026-08-17
**Host:** windows (yolanda)
**Audience:** the linux-mutable coordinator holding the cut
**Classification:** research/
**Orders:** 798-emje (closed this cycle), 795-jeym (blocked, premise refuted),
757-4hdt, 735-ewzp

## The one-line answer

**The promotion verdict does not change. v0.4.260815.1 still fails, and this
cycle does not make it promotable.** What changes is the recorded *cause*, and
therefore what the next cut has to contain.

## What the hold was pointed at, and why that was wrong

The coordinator was pointed at **795-jeym**: "the daemon binds vsock only after
minutes of provisioning work, so a cold-boot readiness probe times out." That
premise came from a stale code comment — 757-4hdt's *first* diagnosis, which
757-4hdt itself superseded two events later — and it was refuted by measurement
last cycle: across four cold boots the listener answers **61–255 ms** after
daemon start, and on the truly-cold boot it was bound **36 ms before
provisioning began**. The bind was never late. See
`plan/issues/guest-vsock-bind-ordering-refuted-2026-08-17.md`.

Cost: a p1 release-blocker filed against a defect that did not exist.

## What was actually wrong

**798-emje.** The readiness probe connects to CID 1 (`VMADDR_CID_LOCAL`), which
requires the `vsock_loopback` kernel module — and the module load *raced* the
probe. That is the one variable that differed between 757-4hdt's recorded FAIL
and PASS on identical artifact and host: `preflight vsock_loopback missing`
versus `... loaded`.

Two paths were racing, and this cycle made both deterministic:

- **boot path** — `tillandsias-headless-ready.service` now declares
  `After=`/`Wants=systemd-modules-load.service`. Verified in systemd's own
  resolved graph, not just in the file.
- **clean-room path** — provisioning used to write `modules-load.d` and
  `modprobe` at the *end* of `inject_bootstrap_logic`, ~60 lines *after*
  `systemctl enable --now`. It now loads and **confirms** the module *before*
  starting any unit. The 249 ms gap 757-4hdt measured was those two statements
  in the wrong order, not a slow kernel.

Evidence: 3 kernel-cold boots of the fixed config → 3 identical `before=loaded`
/ `vsock_listener=bound` verdicts; 1 adverse kernel-cold boot with the
`modules-load.d` entry deleted → `before=missing after=loaded`, i.e. the
backstop caught it *and said so*; three-state matrix re-falsified by execution
(bound 0 / NOT-BOUND 1 / INDETERMINATE 2).

## Why the verdict still stands

1. The fix is in the **source tree**, not in the published tag. v0.4.260815.1
   ships the racing configuration.
2. That tag *additionally* still carries 757-4hdt's `ExecStartPost` shape — a
   probe wired where failing it **stops the healthy daemon it measures**. That
   genuinely broke clean-room provisioning of this exact tag, and it is a
   separate, already-fixed-in-tree defect.

So the FAIL was correct. Only its explanation was wrong.

## What the next cut needs

- 798-emje's ordering fix (this cycle),
- 757-4hdt's separate-unit readiness assertion (already in tree),

and then a clean-room provision re-run on a host permitted to overwrite its
guest binary — which yolanda is not, by standing operator directive. That re-run
is the remaining gate, and it belongs to a host that can do it.

## What must not be "simplified" while clearing this

`INDETERMINATE` (exit 2) is a **real third state**: "this probe cannot observe
the property from here" is not the same fact as "nothing is listening". Folding
it into PASS reproduces 735-ewzp (a probe that always passes); folding it into
FAIL reproduces 757-4hdt's false alarm on a healthy system. Both have shipped
once already. Pinned by
`litmus:guest-vsock-loopback-ordered-before-readiness-probe`.
