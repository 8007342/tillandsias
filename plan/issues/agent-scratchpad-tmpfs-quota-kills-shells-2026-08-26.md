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

| | `df` claims | real wall (`quota -s`) | gap |
|---|---|---|---|
| calmecacpilli | 3.9 GB (3934 MiB) | 3148 MiB | ~20% overstated |
| macuahuitl | ~31 GB (31744 MiB) | 25564 MiB | ~20% overstated |

**BOTH NUMBERS ARE NOW MEASURED.** macuahuitl's wall was originally recorded
here as "at or below ~18 GB (inferred)"; their shell recovered and `quota -s`
returned **25564 MB**. The inference was confidently reasoned and wrong by
~7 GB, which is why it was recorded as an inference. Replaced.

**AND IT IS A SYSTEMD DEFAULT, NOT LOCAL POLICY** — verified independently on
both hosts. `/usr/lib/systemd/system/tmp.mount` ships:

    Options=mode=1777,strictatime,nosuid,nodev,size=50%,nr_inodes=1m,x-systemd.graceful-option=usrquota

Nobody restricted these machines; stock systemd did. **So this is fleet-wide by
construction**, on every host whose `/tmp` comes from systemd, and the small
scratchpad here is not a local quirk.

**THE QUOTA APPEARS TO BE ~80% OF THE MOUNT SIZE**, which makes the wall
predictable from `df` even without `quota -s`:

    calmecacpilli:  3148 / 3934  = 0.8002
    macuahuitl:    25564 / 31744 = 0.8053

n=2 hosts, so treat the ratio as a rule of thumb rather than a constant — the
0.5% spread may be rounding in the RAM figure or may be real. **`quota -s`
stays the authoritative check**; the ratio is useful only for predicting
whether a planned write is anywhere near the wall before bothering.

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

## The builds were the TRIGGER, not the cause

macuahuitl initially reported — and this file initially recorded — that their
own concurrent builds filled the quota. With a shell back, they measured it and
corrected themselves: after deleting their ~9.6 GB, `/tmp/claude-1000` still
held **12 GB from a DEAD session**, idle since 2026-08-25 — a 4.4 GB
`warm-store`, a 2.5 GB cargo `ctarget`, and 545 MB `proto-store` across 114
directories. With ~3 GB of other `/tmp` residue: 12 + 3 + 9.6 ≈ 24.6 GiB
against a 24.96 GiB quota.

**So the scratchpad was already at ~95% before the builds started.** Any
moderately large write would have wedged that session; the builds merely got
there first.

That changes the remedy's shape. A rule of "do not build in the scratchpad" is
necessary and **not sufficient** — a host can be one careless write from EDQUOT
with no build involved, because *dead sessions do not clean up after
themselves*. The 4.4 GB `warm-store` in that residue was nix-cache staging: a
sibling doing legitimate work, unreaped for a day.

This is the same unreaped-state shape as the 13 agent worktrees at 60 GB
recorded on order 863-iicc criterion 4 — different directory, same absence of a
reaper.

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
