# Concurrent ledger append without manual merges — empirical verdict (581-jf7g)

Author: big-pickle (linux forge), 2026-08-02
Spec anchor: `@trace spec:methodology-accountability`
Follow-on: plan/issues/work-order-id-collision-free-design-2026-08-01.md
Packet: `concurrent-ledger-append-without-manual-merges` (order 581-jf7g)

## The question

The operator asked for concurrent packet creation "without triggering manual
merges every time". Collision-free order IDs (order 566) removed the SEMANTIC
half — no renumbering, no reference chasing, no "which 568 did you mean". The
MECHANICAL half remains: two hosts appending to the end of one
`plan/index.yaml` still produce a git text conflict, resolved by hand on
2026-08-01 (keep both sides, drop three markers).

This packet empirically settles the two candidate mechanisms against the real
failure. The real failure is NOT that merges happen — it is that a HUMAN must
adjudicate them. A conflict a machine resolves correctly and verifiably is
acceptable; one requiring judgement is not.

## Empirical setup

A minimal two-branch fixture was built for each scenario. Baseline (plain git,
no driver) vs. candidate (`.gitattributes` `plan/index.yaml merge=union`),
merging two divergent branches both editing the same packet/region back into
`master`. Every post-merge result was fed to `tillandsias-plan check`.

All work was performed in `/tmp/opencode/ut*`; full transcripts were captured
and the corrupted outputs saved to `/tmp/opencode/*-corrupted.yaml`.

## Experiment 1 — two hosts append events to the SAME existing packet

Both branches insert a `- type: progress` event into packet `alpha`, at the
same spot, with different timestamps and different summaries.

- **Plain git**: `CONFLICT (content)`, rc=1, one `<<<<<<<` marker block.
  Adjudicated by hand.
- **Union driver**: rc=0, no conflict markers. Result is **malformed**:

      - type: progress
        ts: "2026-08-02T10:00Z"
        summary: "host-a: milestone one"
        ts: "2026-08-02T11:00Z"
        summary: "host-b: different milestone"

  host-b's event lost its `- type:` list marker and its two keys were folded
  into host-a's event. `tillandsias-plan check` catches it:
  `duplicate entry with key "ts" at line 10 column 11`.

## Experiment 2 — both hosts append an event with the SAME summary line

Same scenario, but both sides' new event shares the identical `summary:`
text (a common case — two hosts reporting progress on the same shaped step).

- **Union driver**: rc=0. Result **malformed**: two `ts:` keys inside one
  event (union emits BOTH sides' lines when the hunks overlap), again caught
  by check as `duplicate entry with key "ts"`.

## Experiment 3 — two hosts append a NEW packet at file end

The actual 2026-08-01 failure: each host adds a distinct packet (`bravo` /
`charlie`) to the tail of `plan_index.steps`.

- **Plain git**: `CONFLICT (content)`, rc=1 — a single trailing hunk, both
  sides "modified the last line". This is the manual-merge annoyance the
  operator wants gone.
- **Union driver**: rc=0, result is a **correct** ledger (both packets present,
  valid YAML, `tillandsias-plan check` reports `ok: 3 packets, ids unique,
  live references sound`).

## Verdict

### Union merge driver: REJECTED as a silent merge mechanism

- It does eliminate the mechanical conflict in the common append-at-end case
  (experiment 3) and produces a valid ledger there.
- It is **not safe**: any two hosts editing the same region (experiment 1 and
  2 — and events ARE appended into existing packets constantly, so that region
  is the most frequently edited part of the file) silently produce a malformed
  ledger with **no conflict marker and no human attention**.
- `tillandsias-plan check` happens to catch both corruption shapes tested —
  but that guard is NOT wired into any pre-push gate today. Relying on "check
  runs on every merge and catches it" requires the guard to be enforced
  BEFORE a push, which is exactly the missing gate this packet flagged.
- Even with the guard wired, union's failure mode is probabilistic: it
  emits both sides' lines, and whether that is "two valid events" (fine) or
  "one event with duplicated keys" (caught) or "two events for the same
  semantic fact" (NOT caught — duplicate-event semantics) depends on the
  exact line alignment. A mechanism whose correctness depends on hunk
  alignment is not a mechanism you can trust unattended.

### One file per packet under plan/packets/: REJECTED for now, kept as the long option

Structurally removes the conflict — two hosts filing concurrently touch
different files, so even plain git merges cleanly. But it is a large migration
of a 499-packet ledger and its tooling, and the ledger's append-to-existing-
packet traffic (events) remains a shared-region problem inside whichever file
the packet lives in. `plan/steps/` is a legacy markdown format the plan crate
does not read, so it provides no head start.

### Recommendation: KEEP manual resolution as the baseline, and close the real gap — a pre-push guard

The correct move is the cheapest one that changes the actual failure class:

1. **Keep the plain git merge** (no union driver). Two hosts appending
   distinct packets conflict at the tail; the 2026-08-01 resolution (keep
   both sides, drop three markers) is a ten-second mechanical edit, and every
   such merge is attended by a human who sees both sides.
2. **Close the "malformed ledger reaches a push" hole**: wire
   `tillandsias-plan check` into the pre-push gate so a YAML-parse failure or
   duplicate order token cannot be pushed. `build.sh --check` does NOT run it
   today, and `release.yml` does not either. This is the exit criterion
   "a malformed ledger cannot reach a push undetected" made concrete, and it
   is the piece that makes even the rejected union driver provably unsafe to
   skip — because the guard now exists either way.
3. Record this decision in the packet so nobody re-proposes union merge
   without the empirical record above.

## Files touched by this decision

- `plan/issues/concurrent-ledger-append-without-manual-merges-2026-08-02.md`
  (this decision record).
- Packet `concurrent-ledger-append-without-manual-merges` (581-jf7g) updated
  to completed with this verdict and the pre-push-guard follow-on noted.

## Rejected alternatives (with reasons)

- **Union merge driver** — rejected above (silent corruption, probabilistic
  correctness, guard absent).
- **Custom merge driver (e.g. a script that concatenates steps then de-dups
  by packet_id)** — a merge driver that rewrites YAML must itself be
  correct on every input, including the region edits that broke union; it
  reintroduces a human-in-the-loop for its own verification, and git merge
  drivers that mutate beyond conflict hunks are notoriously hard to get right.
  Not worth it for a ten-second manual resolution on a branch-coordinated
  cadence.
- **Per-packet files** — deferred (large migration; events still share a
  region). If manual merges ever become frequent enough to hurt, this is the
  option to revisit.
