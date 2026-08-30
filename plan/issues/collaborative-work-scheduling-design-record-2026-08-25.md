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

**REVISED 2026-08-30 by measurement — see F10.** The first half of that
sentence is false for the recipe the worker protocol prescribes:
`append-event <id> claim` changes no status, so nothing is hidden. F4 is real
only for the four packets that carry an explicit `in_progress`, three of which
are stranded — so its operative problem is abandonment, not latency of return,
and it is smaller than recorded here.

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

---

# Second cycle (lenovinha, 2026-08-29)

Continues the inventory. Three results: F1 is **reproduced on a second host and
reclassified**, and the two entries the previous cycle left as "unexamined" are
now **searched** — one is absent, the other is already built.

## F1 REVISITED. Reproduced on lenovinha, and I am the cause of one instance

**MEASURED first-hand, lenovinha, three consecutive cycles on 2026-08-29/30
(04:5xZ → 06:14Z).** Identical batch every time:

```
epic=architecture-audit-epic role=linux size=5 seed=silverblue-ryzen7-amd+nvidia-lenovinha-20260830 pick=2/7
795-zshi  guest-exec-allowlist-forces-argv-flattening   p1
795-5itp  nine-hand-rolled-length-prefixed-framing-copies p2
335       collaborative-work-scheduling-research        kind:research
245 / 251 unscored
```

This is F1's shape on a different host with a different seed, which is worth
recording on its own: yoga's five-cycle measurement could have been read as a
seed artifact, and it was not.

But the useful part is the causal chain, because I am inside it:

- **Cycle 1** — audited 795-zshi. Three of four `next_action` steps had already
  landed; the only remaining work is two Windows-lane deletions. I wrote that
  into its `next_action`, including the sentence *"suggests re-pointing
  `pickup_role` from `any` to `windows`"* — **and did not do it**.
- **Cycle 2** — the selector offered 795-zshi again, first in the batch, exactly
  as predicted. I skipped it and took 795-5itp. Landing slice 6 narrowed *that*
  packet's remainder to macOS + Windows, and I recorded the narrowing in prose
  `next_action` too.
- **Cycle 3** — the selector offered both again, unchanged.

So F1 did not merely recur: **the cycle that diagnosed it also produced the
next instance of it, in the same commit that named the remedy.** That is a
sharper datum than "routing cannot see the lane", and it moves the entry to a
different class.

### The measurement that reclassifies it: `pickup_role` DOES filter

The previous cycle listed F1 as one of two *live gaps in selection itself*. That
is not what the code does. `select-work-batch.sh` delegates role filtering to
the plan binary, and `PlanIndex::ready()` (`crates/tillandsias-plan/src/lib.rs`
:1005-1013) filters on `pickup_role == role || pickup_role == "any"`.

Measured at HEAD, 2026-08-29:

```
ready linux    318 packets
ready windows  178 packets
windows-ready packets NOT offered to linux: 36
```

The exclusion works. A packet re-pointed to `windows` leaves the Linux pool the
same cycle, with no new machinery and no operator decision.

**So the single-lane half of F1 is a DISCIPLINE failure over an existing
mechanism — the same class as F2, not a missing mechanism.** Nobody updates
`pickup_role` when a slice narrows the remainder to one lane, and the narrowing
gets written in prose instead, which the selector cannot read. That was already
the diagnosis; what is new is that the field it needs already exists and already
works.

Acted on rather than only recorded: 795-zshi is re-pointed to `pickup_role:
windows` in this cycle's commit. If F1 is discipline, the honest response is to
exercise the discipline, not to describe it again.

### What IS a real mechanism gap, and it is one line

`pickup_role` is a scalar with exactly one wildcard. It can say *linux*, or
*windows*, or *any*. It **cannot** say "what remains needs macOS **and**
Windows, but not Linux".

Confirmed rather than assumed — the grammar admits no disjunct:

```
pickup_role: linux    275     pickup_role: operator    7
pickup_role: any      259     pickup_role: tlatoani    3
pickup_role: windows   55     pickup_role: forge       2
pickup_role: macos     36
```

Zero disjuncts across 637 carriers, and `ready()` does an exact string compare,
so a value like `macos|windows` would match no role at all and silently vanish
from every pool — a fail-quiet, which this packet's mandate forbids.

**Live exhibit: 795-5itp.** After this cycle's slice 6 its remaining work is
5 decodes in `macos-tray/pty_vsock_bridge.rs` and 2 in
`windows-tray/hvsocket.rs`. Every available value is wrong:

- `any` — what it has now. Keeps offering it to Linux forever. This is F1.
- `macos` — hides genuinely-ready work from Windows. Strictly worse.
- `windows` — same, mirrored.

So the packet stays `any` and stays in my batch, and it will stay there until
the grammar can express its remainder. **That is the actual gap, and it is far
smaller than anything on this packet's candidate list**: make `ready()` accept a
`|`-separated disjunct, plus a value grammar and a validator that refuses an
unknown lane so the fail-quiet above cannot happen.

**Verifiable closure (proposed, NOT adopted — criterion 4 reserves that for the
Tlatoāni):** a test asserting that a packet with `pickup_role: macos|windows`
appears in `ready macos` and `ready windows` and NOT in `ready linux`; plus a
validator arm refusing `pickup_role: mac|windows` by naming the unknown lane,
so a typo cannot silently empty a packet from every pool.

**Migration rung:** the field is additive and every existing scalar value keeps
its exact meaning, so the rung is one commit with no ledger migration. The
adoption half is the discipline half above, and it needs no code at all.

## F7. Thrashing mediation — SEARCHED, no evidence in the ledger

The packet's outcome text names "thrashing mediation cases" among the failure
modes to survey. The previous cycle left it unexamined and said so.

Searched at HEAD: `thrash` appears **6 times in `plan/index.yaml`**, and not one
is a scheduling case.

- 2 are this packet's own outcome text and the previous cycle's note about it —
  i.e. the term citing itself.
- 1 is GPU memory (`spill to host RAM or thrash`, the accel-tier work).
- 1 is NTFS I/O (`we are thrashing NTFS`, the Windows build-offload report).

So the word entered this packet's mandate from the 2026-07-14 operator
directive without a case behind it. **Absence here is now SEARCHED, not
unexamined** — which is the distinction the previous cycle explicitly asked its
successor to close. If thrashing mediation is a real concern it is a
*predicted* mode, and by this record's own rule (predicted vs observed) it must
not enter the mechanism set until something measures it.

## F8. Milestone-burndown surfacing — ALREADY MECHANISED

Also named in the outcome as a candidate mechanism. It exists:

```
$ tillandsias-plan burndown architecture-audit-epic
245      ready       network-architecture-audit
246      obsoleted   credential-secrets-architecture-audit
...
795-hzpg completed   podman-sync-wait-bounded-busy-polls-two-detached-threads
```

`burndown` is in the binary's own `capabilities` set and is exposed as the
`plan_burndown` MCP tool. It reports terminal states (`obsoleted`, `completed`,
`implemented`) alongside open ones, which is what makes it a burndown rather
than a queue view.

This joins F3 and F6 in the already-mechanised column. Whatever remains here is
about *surfacing* it in `loop_status` — a habit, not a mechanism — and this
record should not carry a mechanism proposal for it.

## Where the inventory stands after this cycle

Eight entries. **Four already mechanised** (F3, F6, F2's claiming, F8), **two
discipline problems over existing mechanisms** (F2, and now F1's single-lane
half), **one predicted-but-unmeasured** (F7), and **two live gaps**: F1's
multi-lane half (`pickup_role` cannot express a partial-lane remainder) and F4
(a claim hides work in both directions with only a reaper to return it).

The mandate was the SMALLEST mechanism set that fixes what we actually hit. On
the evidence now recorded that set is **two changes, one of which is a single
predicate**, and **four of the packet's own five named candidates are foreclosed
by measurement**: better seeding (F5, refuted), dependency-aware dispatch waves
and priority lanes with aging (traceable to no entry), and milestone-burndown
surfacing (F8, already built). Per-host reservations survive only as F4's
candidate remedy, not on their own merits.

## Still not done

- **Criterion 2, the prior-art survey with provenance, is still not started.**
  I did not start it deliberately: the mechanism surface has shrunk twice now
  under measurement, and surveying CI schedulers and OS run-queues to justify a
  one-line predicate change would be the ad-hoc growth this packet exists to
  prevent. It should be scoped to the two surviving gaps — attention/lane
  routing for F1, and lease-visibility for F4 — rather than to the original
  five candidates, four of which no longer have a problem attached.
- **F4 is untouched since the previous cycle.** It is now the larger of the two
  live gaps and has no first-hand measurement on this host.
- **Criterion 4 (Tlatoāni sign-off) is not sought here.** Nothing in this cycle
  became worker-protocol contract: the `ready()` disjunct is a proposal, and the
  795-zshi re-point uses the existing field as designed.

## F9. A slow gate starves a fast lane: five lost push races in one cycle

**MEASURED first-hand, lenovinha, 2026-08-29 ~06:20–06:40Z, while landing this
very section.** Five consecutive `git push origin linux-next` refusals as
non-fast-forward, each after a full rebase + `./build.sh --check`. Landed on the
sixth.

The mechanism is arithmetic, not bad luck:

- The pre-push hook is the trunk's only gate and it stamps a specific TREE. Any
  rebase onto a new upstream commit changes that tree, so the gate must re-run.
- `./build.sh --check` reports `Gate phases totalled ~186s` on this host.
- A peer host was pushing roughly once per minute (`dd8e3650b` 23:24:52,
  `cc8a1feb1` 23:23:52, `879f7537e` 23:16:10, `d376fb896` 23:04:26).

A 3-minute gate cannot win a 1-minute race except by luck. The host is not
blocked and nothing is broken — it simply burns ~3 minutes of gate per attempt
until the peer's burst ends. Like F1, the cost is real and invisible in
burndown.

**What makes it a scheduling entry rather than a build-time complaint** is that
the changeset was *plan-only*: two `plan/index.d/` fragments, one
`plan/issues/` record, one work-queue line — and `plan/index.yaml`. The hook
already HAS a fast lane for exactly this shape, and it declined:

```
plan-only lane: not applicable — 'plan/index.yaml' is outside
plan/index.d/, plan/loop_status.d/, plan/issues/, and
plan/mo-full-attestations.d/ (full gate required)
```

The lane is correct to exclude the folded index in general. But the folded
index is *where `append-event` writes* when a packet lives in `plan/index.yaml`
rather than in a fragment — so any cycle that records an event on a folded
packet is pushed out of the fast lane by the ledger tool's own write target,
not by anything about its content.

**Not proposed as a mechanism here, deliberately.** Two candidate remedies are
visible and both need measurement this entry does not have: teach the fast lane
to accept a `plan/index.yaml` diff that is *additive within `events:`*, or make
`append-event` always write a fragment and let the fold be regenerated. Either
touches the ledger's write path, which is F3/F6 territory and well outside a
scheduling record's authority. Recorded here because it is a measured
starvation mode in the same family as F1 and F4 — work that exists, is ready,
and cannot reach the pool — and because the next host to lose six pushes in a
row should find it written down rather than rediscover it.

## F10. Claiming does not claim — the sanctioned recipe changes no status

**MEASURED first-hand, lenovinha, 2026-08-30, over seventeen consecutive cycles
of real claiming on this host.**

F4 is recorded above as *"a claim hides work from the pool immediately and
returns it only via a 24h reaper"*, with the asymmetry named as the defect.
For the recipe the worker protocol actually prescribes, **the first half is
false**: nothing is hidden, because nothing changes.

### The measurement

Packet 245 carries **43 `claim` events** — eleven of them mine, one per cycle.
At HEAD it is `status: ready` and still returned by `ready linux`. So are 335
and 251, both claimed repeatedly by this host.

Fleet-wide at the same moment:

```
ready linux                 316 packets
in_progress (expire-claims)   4 packets
  of which stranded            3
```

Four packets in the whole ledger carry `in_progress`, and three of those four
are past their TTL. So where the status IS set, the dominant outcome is
abandonment — and where the protocol's own recipe is followed, the status is
never set at all.

### Why: the rule describes a transition the tool does not perform

`methodology/distributed-work.yaml` states, in `rules`:

> "A `claim` event changes status from ready to in_progress (mint lease_id;
> heartbeat per lease rules)."

The worker skill §3 implements claiming as
`tillandsias-plan append-event <id> claim …`. That command's whole usage is
`<ref> <type> <summary> --ts <ISO> [--agent A] [--host H]` — **there is no
status flag**. Appending an event cannot change a status; only
`set-field status in_progress` can, and neither the rule nor the skill's claim
step says to run it.

### The same sentence was already found false once, two rules below

The same `rules` block says:

> "A `completed` event REQUIRES evidence_refs and sets status to `completed`"

That is equally untrue of the tool, and the worker skill's §7.2 exists
*precisely because it is untrue* — it is three paragraphs long, cites
600-c266 and 635-i6vm, and opens *"An event alone does not close a packet."*
Three hosts left finished work claimable on 2026-08-09 before that was written.

**The claim rule is the same sentence shape and was never corrected.** The
fleet learned the lesson on the closing end and did not carry it back to the
opening end.

### What this does to the inventory

- **F4's asymmetry is not the operative defect.** Work is not hidden by
  claiming; it is hidden only by the rare explicit `in_progress`, and the
  3-of-4 stranded rate says that path's problem is abandonment, not latency of
  return. F4 remains real for those four packets and is *smaller* than recorded.
- **F2 gets worse, not better.** 814-iyu7's duplicate implementation led the
  fleet to add a claim step to the skill (commit 7fff8d2a2). That step runs on
  every host every cycle and separates nothing: two hosts claiming the same
  packet both see it `ready` and both proceed. The mechanism that was "existing
  but unused" is now *used and inert* — which reads as fixed in every cycle
  report.
- **F5's finding stands unrescued.** Selection does not separate concurrent
  hosts, and claiming was the answer; it is not one.

Filed as **order 943-unii**. The fix is a decision, not an obvious edit: either
the claim step gains a status transition (and `ready` stops offering claimed
work, with everything that implies for the 3-of-4 stranded rate), or the rule
is corrected to say a claim event is an audit record and NOT a mutex — but the
current state, where the contract promises exclusion the tool does not deliver,
is the one state that cannot be right.
