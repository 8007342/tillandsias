# Triage heuristics — fat-agent research (2026-08-09)

Classification: `research/`
Packet: 630-6nw5, milestone 630-67jk (convergence velocity)
Snapshot: 219 ready packets, `tillandsias-plan query --status ready --limit 400 --json`

The operator's assessment was that the current triage is "rigid and
shortsighted". The measurements below are worse than that: two of the three
scoring terms in `scripts/select-work-batch.sh` are not merely weak, they are
**actively wrong**, and the grouping key does not deliver the property the whole
script was written to provide.

---

## Finding 1 — `priority` ranks by RECENCY, and cancels the term next to it

`priority` is not sparsely applied. It is an artifact of authoring date.

| order bucket | packets | with `priority` | with `release_target` | with tags |
|---|---:|---:|---:|---:|
| 100–199 | 12 | 0 | 0 | 12 |
| 200–299 | 12 | 0 | 0 | 12 |
| 300–399 | 28 | 0 | 16 | 28 |
| 400–499 | 36 | 0 | 17 | 36 |
| 500–599 | 87 | 2 | 34 | 82 |
| 600–699 | 44 | **43** | 10 | 39 |

43 of 45 priorities live in the last 44 packets, and **every ready p0 has order
≥ 598**. So `2*urgency` does not rank by importance — it ranks by recency.

The score is `2*urgency + 1.5*blocking + neglect`, where `neglect` rewards *old*
packets. The two largest terms therefore **partly cancel each other**. This was
invisible while the projection bug held urgency at a constant 0 (627-cx24);
fixing the projection is what would have activated the conflict.

`capability_tags` is the only field with flat coverage across all six eras.

## Finding 2 — the dominant epic provides almost no cohesion

Mean pairwise Jaccard over tag sets. **Random-pair baseline = 0.041.**

| `release_target` group | n | cohesion |
|---|---:|---:|
| forge-local-experts-milestone | 48 | **0.110** |
| credential-lifecycle-audit | 4 | 0.504 |
| harness-mcp-expert-validation | 3 | 0.389 |
| stable-milestone-v1 | 4 | 0.084 |
| web-share-release | 8 | 0.081 |

The mega-epic holds **62% of all grouped work** and scores 2.7× baseline —
barely better than three random packets. Only the 3–4-packet groups are
genuinely cohesive.

This is the finding that matters most: selecting that epic buys nearly no
cohesion, which means `select-work-batch.sh` has been producing **the same
scatter it was written to prevent, now wearing an epic label**. A cohesion
guarantee that is not measured is not a guarantee.

Anchor-tag buckets do much better: credentials (16) **0.261**, experts (28)
0.180, mcp (23) 0.176, rust (29) 0.171, inference (33) 0.165, security (36)
0.159, podman (31) 0.135.

Hard Jaccard partitioning is NOT viable — at ≥0.4 there are 143 components and
115 singletons; the tag vocabulary is long-tailed (119 of 273 tags occur once).
**Overlapping anchor-tag buckets, not a partition.**

## Finding 3 — `kind` carries real urgency, measured by revealed preference

Declared `priority` is broken, so test against what actually got drained.
Stock/flow across 312 completed vs 199 ready packets:

| kind | % completed | % of ready backlog |
|---|---:|---:|
| bug + fix variants | **39.4%** | 20.1% |
| enhancement | 22.1% | 6.5% |
| implementation | 8.7% | **22.1%** |
| research | 10.9% | 12.6% |

Bugs and enhancements drain 2–3× faster than they accumulate; `implementation`
accumulates. Only **6 of 312 completed packets ever carried a priority**, so
declared priority cannot see this at all.

Counter-evidence, honestly cited: orders 148, 270, 273, 382 are all `bug` and
have sat ready for 250–480 order-ticks. `kind=bug` means "usually drained fast",
not "always urgent" — it earns a **modest additive bonus, never a dominant
multiplier**. `kind=security` is unusable alone (n=1); the `security` *tag* (36
packets) is the right handle, and only 4 of those carry any priority.

## Proposed scoring function

Group by **anchor tag** — each packet joins the bucket of its rarest tag with ≥3
members; the 10 tagless packets form one `UNTAGGED` bucket.

```
score = 1.0*cohesion + 1.0*neglect + 0.8*kind_urgency + 0.6*blocking + 0.5*declared_priority

  cohesion          mean pairwise Jaccard, rescaled (x-0.04)/0.26, clamp 0..1   [209/219]
  neglect           (maxorder - oldest_order)/maxorder                          [219/219]
  kind_urgency      fraction of bucket matching bug|fix|regression              [209/219]
  blocking          min(ready_dependents,4)/4   -- cap 4: the observed max IS 4 [ 98/219]
  declared_priority (3-best_rank)/3, applied ONLY when set; NO p3 default       [ 45/219]
```

Priority survives as the *smallest* term: real when present, recency-biased in
aggregate. Dropping the `// "p3"` default is load-bearing — today an unset
priority scores identically to a deliberate p3, which is the original defect in
its general form.

**Considered and rejected:** `release_target` as the grouping key (35% coverage,
mega-epic cohesion 0.110 — it is a *release* label, not a *work-cohesion* label;
demote to tiebreak). `desired_release` (83% one value). `status` (constant).
`pickup_role` as a score term (hard filter; 6 of 12 values are free-text prose
like `"linux (XDNA2 lane) + macos (Metal lane)"` that no `case` matches).
`deliverable` path-prefix (mostly unique `plan/issues/*.md`, no clustering
power). `title` TF-IDF (17 empty titles). Event-count circling penalty (events
unevenly written — see below).

## Evaluation harness — and why precision@K would lie

Exists: 1005 commits touching `plan/index.yaml`, 99 touching `plan/index.d/`;
each commit replays an exact historical ledger via `git show <sha>:plan/index.yaml`.
559 packets, 312 completed, and **100 packets carrying both a claim and a
completed event** — the labelled set.

Method: at each ready→in_progress transition, reconstruct the parent ledger, run
both scorers, and check whether the packet actually claimed appears in the top-K.

**The trap, stated plainly: the ground truth is contaminated.** Agents chose
using the incumbent score, so precision@K measures *agreement with the scorer we
are trying to replace*. The honest primary metrics are **batch cohesion** (mean
pairwise Jaccard of the emitted batch) and **starvation** (max order-age ever
selected); precision@K is a sanity check only.

Not determinable: only 145 claim events for 312 completions, so ~54% of "what
was chosen" must be inferred from commit diffs. Two incompatible event schemas
(`index.yaml` uses `- type: X / ts:`; fragments use `- ts: / event: X`).
Timestamps are agent-written, minute-granularity, mixed `Z`/offset. **No token or
time cost is recorded per packet**, so "cheaper cycle" cannot be measured from
history at all — which is exactly why 630-d2jv must land before any velocity
claim.

## Data-quality defects found along the way

- 17 ready packets have an **empty-string title**; 12 have an empty-string
  `deliverable`. Both are absent-wearing-a-default, the same shape as the
  `priority` bug.
- `order` is **mixed-type**: 133 integers, 86 strings, one `392b`.
- 6 of 12 `pickup_role` values are prose, not role tokens.

## Recommendation

Do **not** hand-tune `select-work-batch.sh` from this report. Land 630-d2jv
first, build the replay harness, and evaluate the proposed function against
cohesion and starvation before changing selection behaviour — the incumbent was
shipped on exactly the intuition this research just falsified.
