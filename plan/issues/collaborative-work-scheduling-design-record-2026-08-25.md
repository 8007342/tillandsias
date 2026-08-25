# Collaborative work scheduling — design record (order 335)

Deliverable half of `collaborative-work-scheduling-research`. This file opens
the **failure-mode inventory** (exit criterion 1). It is a PARTIAL slice and
says so: the prior-art survey (criterion 2) and the mechanism proposals with
verifiable closures are not started here.

The packet's own framing is the constraint to keep: propose the SMALLEST
mechanism set that fixes what we ACTUALLY HIT, and reject anything that cannot
fail loud. So this inventory records only failure modes with ledger evidence —
no hypotheticals, and each entry says whether it was measured first-hand or
inherited from the record.

## Why the inventory comes first, and what it is for

`methodology/distributed-work.yaml` → `release_target.known_limits_and_next`
already predicts the shape: *"agents can still contend for the same packet or
idle when their platform's targeted set is blocked."* Both halves have now
happened. An inventory that distinguishes PREDICTED from OBSERVED is what stops
the mechanism list growing to cover imagined problems — which is the failure
this packet was created to avoid ("do not grow this section ad hoc").

## F1. A host is offered work it cannot advance, for cycles on end

**Order 884-hfsj. MEASURED first-hand, yoga, five consecutive cycles on
2026-08-25 (09:43Z → 17:43Z).**

Every cycle selected the identical batch (`epic=architecture-audit-epic
role=linux size=5 seed=yoga pick=2/7 route=rank:6/7:width=7`), four of whose
five items cannot be advanced by a Linux host. All four say `pickup_role: any`
— which was TRUE when they were filed and stopped being true as slices landed.

The mechanism: `pickup_role` records who could CLAIM a packet, not what its
REMAINING work needs. As slices complete the remainder narrows to one lane, and
that narrowing is recorded only in prose progress events. The selector cannot
read prose.

This is the predicted "idle when their platform's targeted set is blocked",
except the host does not idle — it pays the orientation cost every cycle and
then finds work elsewhere in the batch. The cost is invisible in burndown,
which is why it went five cycles before being written down.

**Refuted remedy, measured in the same cycle:** honouring the existing
`owner_host` field. 45 carriers of 596 packets, zero `macos` values, and none
of the four stuck packets carries it — it would not have prevented a single
cycle. Recorded on 884-hfsj so nobody builds it.

## F2. Two hosts implement the same packet independently

**Order 814-iyu7. Inherited from the record** (meta-orchestration skill,
"Cycle batch triage"). On 2026-08-18 two hosts implemented 798-tk7b six minutes
apart, ~4h duplicated.

Root cause named there: `expire-claims` reported `in_progress=0` — nothing had
been claimed at all, so every host was offered every packet. The mechanism to
prevent it (claiming) existed and was sitting at zero use.

Inventory note: this is a DISCIPLINE failure over an existing mechanism, not a
missing mechanism. A scheduling proposal that adds machinery here would be
treating the wrong layer.

## F3. Deterministic order-number collisions

**Orders 560–562 and 568–570, 2026-07-31. Inherited from the record**
(skill, "Filing a packet"). Two hosts filing in the same window computed "the
next free order" from a ledger snapshot that was stale the moment either
committed, and deterministically picked the SAME number. Six collisions sit at
HEAD.

Already fixed by `tillandsias-plan next-order` + immutable fragments, and the
order token is explicitly permanent. Listed because the inventory should record
what the CRDT design already solved — a scheduling proposal must not
re-litigate it.

## F4. Work stranded invisible in both directions

**Order 641-e2qa. Inherited from the record.** 21 packets sat `in_progress`
with no progress event ever recorded — ~9% of the live ledger, oldest at order
153. A claimed packet is invisible to `ready` queries AND uncounted in
burndown, so nobody claims it and nobody notices it is unfinished.

Still live as a class: `check-stranded-in-progress.sh` reported
`stranded=2` on this host across cycles 2026-08-25T09:43Z–17:43Z.

Inventory note: the asymmetry is the defect. A claim hides work from the pool
immediately and returns it only via a 24h reaper.

## F5. Selection does not separate concurrent hosts by itself

**Measured 2026-08-19, inherited from the record** (skill, "Cycle batch
triage"): three distinct seeds produced a byte-identical batch. Two independent
causes, neither fixable by reseeding — the default seed varies by host KIND and
date rather than by host, and an `urgent=` override is a property of the PACKET
and so preempts every host at once.

Separation comes from claiming (F2), not from the seed. Listed because "add a
better hash" is the obvious wrong proposal and the measurement forecloses it.

## F6. Two cycles contend for one checkout

**Order 873-zcim. Inherited from the record.** A cycle launched by an operator
prompt or a cron acquired no lock and stacked on a running driver cycle in the
same worktree — measured on yoga 21 minutes into a driver cycle, duplicating
its claims. The lock guarded the LANE; what two agents contend for is the
CHECKOUT.

Inventory note: adjacent to scheduling but distinct — a resource-exclusion
problem, not a queueing one. Its resolution (a checkout lock, sanctioned
concurrent work only in a separate worktree) is already landed.

## What the inventory says so far

Of six recorded modes, **three are already mechanised** (F3 order allocation,
F6 checkout lock, and F2's claiming — which exists but was unused), **one is a
discipline problem over an existing mechanism** (F2), and **two are live gaps
in selection itself**: F1 (routing cannot see which lane the remaining work
needs) and F4 (a claim hides work from the pool with only a 24h reaper to
return it).

That ratio matters for the packet's mandate. The SMALLEST mechanism set that
fixes what we actually hit looks, on this evidence, like **two** changes rather
than the five candidates the packet lists — and neither of the two is
"dependency-aware dispatch waves" or "priority lanes with aging". Whoever
continues this should be suspicious of any proposal not traceable to a numbered
entry above.

## Not done here

- Criterion 2, the prior-art survey with provenance, is not started.
- Mechanism proposals with verifiable closures and migration rungs: not
  started. F1 has a filed packet (884-hfsj) with its options narrowed to two;
  that is a candidate rung, not a proposal.
- The inventory is not complete. Thrashing-mediation cases and
  milestone-burndown surfacing, both named in the packet's outcome, have no
  entry yet because I did not find citable evidence for them in one cycle;
  absence here means unexamined, not absent.
