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

## Verified on calmecacpilli, where the margin is worse

    findmnt -no OPTIONS /tmp
      -> rw,nosuid,nodev,seclabel,nr_inodes=1048576,inode64,usrquota
    df -hT /tmp
      -> tmpfs  3.9G

**The scratchpad here is a 3.9 GB tmpfs. A cold `./build.sh --check` in a fresh
worktree costs 4.4 GB** (macuahuitl's measurement). So on this host a lane built
in the scratchpad does not merely risk the quota — **it exceeds it by
construction**, and would kill the session outright.

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
2. A cheap preflight probe: if the scratchpad is tmpfs, report its size and
   remaining quota, so an agent about to do something large sees the ceiling
   before it hits it rather than after. This is a *report*, not a gate — a host
   with a small scratchpad is degraded, not broken.

Deliberately not proposing that anything auto-relocate or auto-clean the
scratchpad: the same tree may hold another agent's in-flight state, and
automated deletion of working state is what `872-c9nd` exists to forbid.
