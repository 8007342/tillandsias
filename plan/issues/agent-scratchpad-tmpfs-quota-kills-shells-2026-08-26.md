# The agent scratchpad is a RAM-backed tmpfs with a quota — building in it kills the session, not the host

- Date: 2026-08-26
- Hosts: macuahuitl (incident), calmecacpilli (verified same exposure, worse margin)
- Class: `optimization`
- Owner: unassigned

## What happened

macuahuitl ran a lane worktree plus two concurrent full-workspace `cargo build`
runs inside their agent scratchpad. The scratchpad lives under `/tmp`, which is
a RAM-backed tmpfs mounted with `usrquota`. They exhausted the quota, and from
that point every Bash call and every file write returned `EDQUOT`.

**The host was fine throughout** — load 0.00, 34 GB available. Only the agent's
own tooling was dead, which is why their first diagnosis was CPU/RAM exhaustion
from the builds. It was the quota.

The measurements they had just taken survived only in their transcript; they
could not commit them, and relayed them to another host to record.

## `df` IS THE WRONG CHECK — it overstates headroom on BOTH hosts

This section originally prescribed `df -hT /tmp` and reported this host's wall
as 3.9 GB. macuahuitl corrected it — on their host `df` reports ~13 GB free
while a 5 KB write returns `EDQUOT` — and measuring the quota here showed the
same defect in smaller form. **`df` was wrong on the host that wrote the rule.**

Measured on calmecacpilli:

    grep " /tmp " /proc/mounts
      -> tmpfs /tmp tmpfs rw,seclabel,nosuid,nodev,nr_inodes=1048576,inode64,usrquota
         (NO `size=` option -> tmpfs defaults to 50% of RAM)
    df -hT /tmp        -> tmpfs  3.9G          <- what df claims
    quota -s           -> tmpfs  space 6424K   quota 3148M   limit 3148M

**The binding constraint is 3148 MiB, not the 3.9 GB `df` reports.** Neither
host declares `size=`, so `df` shows the 50%-of-RAM default in both cases, and
in both cases the usrquota sits BELOW it. The hosts differ only in margin:

| | `df` claims | real wall | gap |
|---|---|---|---|
| calmecacpilli | 3.9 GB | 3148 MiB (`quota -s`) | ~19% overstated |
| macuahuitl | ~31 GB, ~13 GB free | at or below ~18 GB (inferred) | enough to invite the build |

**A cold `./build.sh --check` in a fresh worktree costs 4.4 GB** (macuahuitl's
measurement). Against a 3148 MiB quota, a lane built in this host's scratchpad
**exceeds the wall by construction** — the original conclusion survives, but the
number that supports it was wrong and too generous.

macuahuitl's quota value is INFERRED, not measured, and should stay that way in
this file until someone confirms it: what is measured there is the mount
options, `Shmem` at ~18 GB, and that the failure is `EDQUOT` (quota exceeded)
rather than `ENOSPC` (filesystem full). The inference is that the quota
therefore sits at or below ~18 GB, since 18 GB against a ~31 GB mount cannot
produce `ENOSPC` and the kernel returned the quota error specifically. `quota
-s`, or `repquota` for an operator, would settle it; they cannot run either
from a shell that is already dead.

## The memory signals actively confirm the WRONG hypothesis

This is why two hosts reached for resource exhaustion and neither reached for
the quota. **tmpfs pages ARE RAM**, so the memory readings look like exhaustion
while being perfectly healthy:

    macuahuitl:    load 0.00   MemAvailable 34 GB   MemFree 1.6 GB   Cached 52 GB
    calmecacpilli: MemAvailable 6.0 GB   MemFree 516 MB   Cached 5.8 GB

A reader who checks memory sees a low `MemFree` that looks exactly like
exhaustion — confirming the wrong hypothesis — while `MemAvailable` says there
is plenty. **Both readings are true and neither points at the quota.** So the
misdirection is not merely that the machine looks healthy; it is that the one
diagnostic a careful reader reaches for returns evidence *for* the wrong
answer.

This cycle created a measurement worktree at `/tmp/wt-measure` and deliberately
did not build in it. That is the only reason the session survived to file this.
It was luck rather than judgment: nothing warned, and nothing would have.

## Why it is worth a packet rather than a note

The failure is **silent, total, and misattributed by default**. It presents as
the agent's tools breaking while the machine is visibly healthy, so the first
hypothesis is resource exhaustion — which is wrong, and sends the reader to
`top` instead of to `df`. Two hosts hit or nearly hit it on the same day.

It also composes badly with work already in flight: the multi-worktree question
(order 863-iicc criterion 4) will produce a **lane recipe**, and a recipe is
exactly the artifact that tells the next agent to create a worktree somewhere
convenient. The convenient place is the scratchpad.

## Smallest next action

Two candidates, neither implemented here:

1. Any lane or worktree recipe that comes out of 863-iicc must specify a path on
   **real storage**, and say why — one sentence, in the recipe, where the reader
   already is.
2. A cheap preflight probe: if the scratchpad is tmpfs, report the **quota**
   first and `df` second, so an agent about to do something large sees the real
   ceiling. Prescribing `df` alone is correct on neither host measured so far —
   it overstates by ~19% here and by enough on macuahuitl to invite the build
   that killed them. This is a *report*, not a gate: a host with a small
   scratchpad is degraded, not broken.

Deliberately not proposing that anything auto-relocate or auto-clean the
scratchpad: the same tree may hold another agent's in-flight state, and
automated deletion of working state is what `872-c9nd` exists to forbid.
