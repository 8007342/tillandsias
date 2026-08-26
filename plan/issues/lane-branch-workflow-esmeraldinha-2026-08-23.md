# The lane-branch workflow esmeraldinha is running provisionally, and exactly what it is betting on

- classification: exploration
- filed: 2026-08-23 (windows/ESMERALDINHA), from lane
  `agent/esmeraldinha/windows-next/20260823-low-end-floor` at base `dcb6473d5`
- packet: **863-iicc** (operator-directed, ORCHESTRATOR-GATED)
- status: **provisional practice, not sanctioned fleet policy.** The operator
  directed it and required orchestrator vetting. If the orchestrator rules
  against any part, this host reverts — nothing here is load-bearing for
  anyone else.
- related: 859-4jny (the tactical sibling: make landing work),
  methodology/multi-host-development.yaml `branch_namespaces`,
  orders 499/500 (shipped), 502/503/504 (not shipped)

## Why, in one measurement

> **Corrected.** A first pass quoted a 1.3-minute median inter-commit gap as
> though that were the rate the surface moves. It is a clustering artifact —
> commits arrive in bursts, so the median *gap between commits* is far shorter
> than the median gap a gate actually has to survive. The corrected figures
> below are simulated against the real 72 h timeline. The conclusion held, and
> got sharper.

Over the 72 h to 2026-08-23T15:29Z, **six** identities push to what is
effectively **one surface** — `git rev-list origin/windows-next ^origin/linux-next`
returns **0**, so linux-next already contains everything windows-next has, and
the mandatory pre-push merge of `origin/linux-next` is usually a **no-op that
still costs a full gate**.

The rate is bursty: two dead stretches (18.9 h, 8.4 h) and a live regime since
2026-08-22T23:21Z of **183 commits in 15.38 h = 11.9/h, one every 5.0 min**.
Median inter-*push* gap (commits clustered at 2/5/10 min): **9.1 / 16.4 / 23.2
min** — the same order as this host's entire 9–12 min gate.

Simulating a T-minute gate started at every minute of the burst:

| gate T | P(first attempt beaten) | E[gate runs] | wall clock to land |
|---:|---:|---:|---:|
| 3 min | 0.15 | 1.16 | 3.8 min |
| **10.5 min** (this host) | **0.49–0.61** | **1.86–2.50** | **21–29 min** |
| 15 min | 0.64 | 2.48 | 40 min |
| 30 min | 0.89 | 6.72 | 213 min |

Corroborated twice, independently: this host's **merge ratio is 0.40** (6
`Merge remote-tracking branch 'origin/…'` commits against 9 substantive) — the
highest in the fleet, against macuahuitl 0.11 and **0.00** for lenovinha, yoga
and pirria; and the reflog shows **3 landed cycles paying exactly 6 origin
merges = 2.0 re-merges per landed cycle**. 8 of 8 observed fetches found the
tip had moved.

Two levers fall out, and neither is a branch:

- **The cost is strongly convex in gate length.** Halving the gate beats any
  retry tuning. That is why 863-iicc lists a shorter gate as its
  highest-value optional criterion.
- **This host gates immediately after fetching**, i.e. immediately after
  observing activity — the inspection-paradox worst case. Commit-anchored
  P(beaten) is **0.79–0.82** versus **0.56–0.61** uniformly timed, so simply
  *deferring the gate past a burst tail* is worth ~20 points for free, and
  quiet gaps ≥12 min still cover **70.3%** of even the burst's wall clock
  (longest 64.8 min).

## The workflow

### Per cycle

1. **Fetch and read instructions first.** `git fetch origin --prune`, then
   check whether `origin/windows-next` carries new methodology or a ruling:
   ```bash
   git log --oneline HEAD..origin/windows-next -- methodology/ plan/index.d/ | head
   git diff HEAD..origin/windows-next -- methodology/multi-host-development.yaml | head -40
   ```
   **This is the stop condition.** The moment methodology says something
   different, that wins and this document is obsolete.
2. **Rebase the lane onto the current base** (`origin/windows-next`), which is
   cheap and conflict-free while the lane holds only new fragment files:
   ```bash
   git rebase origin/windows-next     # or merge; see "merge vs rebase" below
   ```
3. **Work.** Commit freely to the lane.
4. **Push the lane freely.** No trunk merge is required —
   `scripts/hooks/pre-push-linux-next-merged.sh` gates exactly
   `refs/heads/osx-next|refs/heads/windows-next`, so a lane ref is not gated.
   The local gate still runs, which is the point: durability without the
   merge treadmill.
5. **Do NOT land every cycle.** Land at the end of a coherent set of work.

### Landing (the "green exit")

There is no sanctioned command — `scripts/lane-exit.sh` is ordered by 502 and
does not exist — so this host does the following by hand and says so:

```bash
git fetch origin --prune
git checkout windows-next && git merge --ff-only origin/windows-next
git merge origin/linux-next          # the pre_push_gate intent, paid ONCE
git merge <lane>                     # merge-only, never squash
./build.sh --check                   # one gate for the whole set
git push origin windows-next
# then VERIFY the claim against the remote, per 859-4jny:
git fetch origin && git merge-base --is-ancestor HEAD origin/windows-next \
  && echo LANDED || echo NOT-LANDED
```

That last check is not optional. 859-4jny caught an ad-hoc land loop reporting
`LANDED on attempt 1` for a push that had been **rejected** — a zero exit
status and a ref-update-looking line in the output are both insufficient
evidence. Ask the remote.

### What still costs a gate

- The lane's **first** push. `pre-push-local-gate.sh`'s plan-only fast lane
  needs an existing remote base to diff against and refuses when
  `remote_sha` is all-zeros, so a brand-new branch always takes the full gate.
- Any push touching non-`plan/` paths.

### What may not need one

The plan-only fast lane (order 668-2xeh, extended by 767-iukh) validates
pushed blobs per file when **every** outgoing path is a NEW fragment. A cycle
whose entire output is `plan/index.d/`, `plan/issues/` and
`plan/loop_status.d/` files may push without a full gate. This host had been
paying full gates for plan-only pushes without realising the lane existed;
that alone is worth more than the branch change on quiet cycles.

## What this bets on, stated as risks rather than buried

1. **No reaper.** `branch_namespaces.sweep_role` binds lane GC to the
   coordinate-multihost-work role with deadlines (merged → delete, idle >24 h →
   salvage packet, >72 h → operator, >14 d → archive). That sweep is **order
   504, pending**. A lane created today is a ref nothing will reap. Mitigation
   while unsanctioned: this host lands or deletes its own lane within 24 h and
   never holds more than one.
2. **Ledger fragments on a lane are the real open question.** `ledger_rule`
   predates the fragment overlays and names only `plan/index.yaml`,
   `plan.yaml`, `plan/loop_status.md`, `methodology/**`. Fragments in
   `plan/index.d/` and `plan/loop_status.d/` are append-only and
   host+timestamp-named, so they cannot textually conflict — but the rule's
   stated rationale is that "every recorded order-number collision came from
   delayed ledger landing". **A minted order token is the collision surface**:
   `next-order` reads the folded ledger, so a token minted on a lane against a
   stale base can collide with one minted elsewhere in the same window.
   Mitigation while unsanctioned: mint order tokens only immediately before
   landing, keep lanes under a day, and accept that a shared prefix is
   explicitly normal per `order_id_allocation` (575-k3f9 / 575-m2p1 are both
   correct and permanent).
3. **Claim visibility.** A claim recorded on a lane is invisible to other
   hosts until landing, so two hosts could work the same packet. The
   methodology already says claims land on the base ref mid-cycle. This host
   therefore still lands CLAIMS to `windows-next` directly and keeps only
   findings on the lane.
4. **Creation is permitted; DELETION is what is contained.** This host first
   read the 2026-08-06 rescope as holding back lane creation. It does not.
   Order 579's containment makes the mirror pre-receive hook reject every ref
   **deletion** before invoking the privileged upstream relay — because port
   9418 is anonymous, keeping a bulk-delete bypass so `lane-exit.sh` could run
   its final `git push origin :<lane>` would let any enclave peer borrow the
   mirror's privileged credential to delete refs. The recorded ruling is that
   **lane creation may remain anonymous as interim containment while deletion
   waits for the authenticated path in order 451**. So creating this lane is
   not jumping a security gate. It does mean risk 1 is sharper than "504 is
   pending": the sanctioned deletion path is *denied*, not merely unbuilt.

5. **No launcher, so the slug is hand-rolled.** `lane_grammar` requires the
   slug be `<mode>-<instance>-<launch-epoch>`, launcher-synthesized and never
   reused. With 502 unshipped there is no launcher, so this lane's slug
   (`low-end-floor`) satisfies `creation_regex` but **not** the documented slug
   shape. Recorded rather than hidden; 863-iicc asks for an interim slug form.

## Why not the operator's literal `windows-side-<feature>`

Stated plainly because it was an explicit instruction and this host did not
follow it exactly. Three mechanical reasons, in increasing order of importance:

1. It is not admitted by `branch_namespaces.creation_regex`. Tested directly
   against the regex from the methodology: `windows-side-low-end-floor` and
   `windows-side-cold-bootstrap` are both rejected;
   `agent/esmeraldinha/windows-next/20260823-low-end-floor` is admitted.
   (Enforcement at rung 2 is **warn-only** today, so it would not have been
   blocked — but it would have been a documented-invalid ref.)
2. It is not enumerated by the coordinator sweep, which operates only on
   `agent/*` and `salvage/*`. The methodology's own words: an out-of-grammar
   name "is a stray that nothing will ever reap".
3. **Decisively: it would not have worked.** The pre-push exemption this whole
   exercise exists to obtain is keyed on the `agent/*` and `salvage/*`
   prefixes. A branch named `windows-side-*` is a "shared non-trunk branch"
   under `pre_push_gate.applies_to` and would have kept the per-push
   trunk-merge requirement — preserving exactly the friction it was created to
   escape.

The operator's intent (a private lane, no per-cycle merge, orchestrator-vetted)
is served; only the spelling changed, and the spelling was the part that
carried the mechanism.

## The workflow demonstrated its own worst failure mode within the hour

Worth recording because it is the sharpest argument in either direction.

An independent reviewer checking whether 863-iicc duplicated existing work
reported that the packet **did not exist**. It was correct: the fragment was
sitting on this lane, unlanded, so `plan_query` / `plan_answer` and every other
host saw nothing. A packet whose entire purpose is to ask the orchestrator for
a ruling had been filed somewhere the orchestrator cannot look — and the
reviewer named that invisibility as "itself the most likely cause of a
duplicate filing".

That is risk 3 above, arriving in under an hour, on the first lane ever used
here. It sharpens the rule rather than refuting the lane:

> **Lanes hold work. They must not hold anything the fleet needs to SEE.**
> Claims, packets, blockers and attestations land on the integration branch
> directly, because their value IS their visibility. Findings, drafts,
> measurements and code-in-progress ride the lane.

Applied immediately: 863-iicc and this document were landed onto `windows-next`
rather than left on the lane, paying the one merge the model says to pay — at
the end of a coherent set of work, not every cycle.

The general form, offered to 863-iicc's exit criterion 2: the question is not
"may fragments ride a lane" as a file-conflict question — they cannot
textually conflict. It is a **latency** question. A fragment whose worth is
immediate (a claim another host must not duplicate, a packet awaiting a
ruling) is worth less the longer it is invisible, so it should not ride. A
fragment whose worth is durable (a measurement, a research note) loses nothing
by landing an hour later. That is a cleaner criterion than a path allowlist,
and it degrades gracefully when someone adds a new fragment directory.
