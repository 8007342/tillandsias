# Order 552's real re-embed cost: 9,909 chunks not 1,592, free on 96% of commits, and 15-45s on the other 4% — async is needed for the TAIL, not the median

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 10)
- status: measured on the sanctioned dev-inference endpoint; **supersedes this
  host's own cycle-1 estimate**
- related: **552** (spec-index commit freshness — this supplies its budget),
  547 (the chunker measured here), 548,
  `plan/issues/esmeraldinha-lower-bound-inference-floor-2026-08-16.md` (corrected)

## Why re-measure

Cycle 1 gave order 552 a budget derived from an **estimate** (`~816k tokens /
512 = ~1592 chunks`) and measured per-chunk cost against a **synthetic**
~500-token chunk, on the bare-metal Windows ollama — a component the operator
has since removed. Every input to that number was a proxy. This run uses the
real chunker, the real chunks, and the sanctioned endpoint.

## The corpus is 6.2x larger and much finer than estimated

`tillandsias-plan spec-index --root . --out <dir>` on the live tree:

```
spec-index: 9909 chunks -> chunks.jsonl        (5,695,953 bytes)
real  0m5.276s
text_len:  min=3  p50=236  p90=712  max=90975   n=9909
```

| | cycle-1 estimate | measured |
|---|---:|---:|
| chunks | 1,592 | **9,909** |
| chunk size | assumed 512 tokens | p50 **236 chars** (~59 tokens) |

Two errors that partly cancel: 6.2x more chunks, each far smaller. Note the
chunker itself is fast and network-free (5.3 s for the whole corpus) exactly as
order 547 designed — chunking was never the cost.

**`max=90975` chars exceeds `nomic-embed-text`'s context window.** All 60 sampled
chunks embedded successfully (768-dim, 0 failures), but the sample's max was
1,688 chars. Whether the outsized chunks truncate silently or fail is
**unmeasured** and worth a look before 552 ships.

## Per-chunk cost, on real chunks, on the sanctioned endpoint

60 real chunks sampled across the distribution (every 165th line), warmed first,
sequential — one request per chunk, the shape a commit-time re-embed would use:

```
ok=60 fail=0 total_ms=41880 per_chunk_ms=698.0
```

**698 ms per real chunk** (cycle 1 said ~2,900 ms, measured against a synthetic
chunk ~4x larger than the real p50).

Full-corpus rebuild: 9,909 x 698 ms = **6,917 s ~= 115 minutes**. Cycle 1 said
62-77 min; the real figure is worse, because the chunk-count error outweighed
the chunk-size error.

## The number that actually decides the design: how much changes per commit

Chunks carry a `content_hash`, so the delta is directly computable. Older trees
were extracted with `git archive` — no worktree or git-state mutation:

| span | chunks then | new | removed | re-embed cost |
|---|---:|---:|---:|---:|
| HEAD~1 -> HEAD | 9,909 | **0** | 0 | **0 s** |
| HEAD~5 -> HEAD | 9,909 | **0** | 0 | **0 s** |
| HEAD~20 -> HEAD | 9,855 | 67 | 13 | **46.8 s** |

Zero for the recent spans because the indexed corpus is
`openspec/specs + cheatsheets + methodology`, and this loop's recent commits were
all `plan/` fragments — **which the spec index does not cover at all.**

Frequency, over the last 567 commits reachable from HEAD:

```
commits touching the indexed corpus: 24  (4%)
corpus files per such commit:        min=1  p50=1  p90=2  max=3
```

At ~21 chunks per corpus file (9,909 chunks / 464 files):

| commit class | frequency | synchronous re-embed cost |
|---|---:|---:|
| does not touch the corpus | **96%** | **0 s** |
| touches 1-3 corpus files | **4%** | **~15-45 s** |

## Conclusion — and a correction to the reason, not just the number

Cycle 1 concluded:

> A **synchronous** commit-time re-embed cannot meet the ~1-2 s budget on the
> floor host **at any realistic delta size**.

The conclusion (async is required) survives. **The reason given was wrong.**
Delta re-embed is not uniformly too slow — it is **free on 96% of commits** and
lands in the operator's "tens of seconds is unusable" band on the other 4%.

The cost is **bimodal**, and that is a worse property than a constant one. An
operation that is normally instantaneous and occasionally stalls 30-45 seconds is
harder to live with than one that always costs 5 s, because the stall is
unpredictable and arrives precisely when someone edits a spec — the moment they
are most likely to be iterating.

So the design guidance sharpens:

- **Async is required for the TAIL, not for throughput.** The median commit needs
  no optimisation at all; it already costs nothing.
- **A "is anything in the corpus dirty?" pre-check is nearly free and skips 96%
  of commits outright** — cheaper than any batching or caching work, and it
  turns the common case into a no-op by construction rather than by speed.
- Batching was measured in cycle 1 at only ~14% better, so it does not rescue
  the 4% case either. The tail needs to be moved off the commit path, not made
  faster on it.

## Caveats

- 60-chunk sample, one host, one endpoint. Per-chunk cost will vary with chunk
  size; the sample's p50 (245 chars) matches the corpus p50 (236) closely, so the
  mean is representative, but a commit that happens to touch large chunks will
  cost more than the 21-chunks-per-file average suggests.
- The ~21 chunks/file figure is a corpus-wide average, not measured per changed
  file. A precise per-commit projection would re-index both sides of each
  corpus-touching commit; the HEAD~20 span (67 chunks over ~3 corpus-touching
  commits, ~22 each) is consistent with it.
- Measured on the CPU lane. Embeddings are **slower** on the iGPU on this host
  (1.58x natively, and Yolanda measured 1.16x slower on AMD via dzn), so the CPU
  lane is the right one and no accelerator work would help here.
