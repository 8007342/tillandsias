# The spec RAG index silently drops 4.6% of the corpus — and 89% of `methodology/distributed-work.yaml`

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 11)
- status: **open — correctness defect, found before order 552 ships**
- related: **547** (the chunker that emits these chunks — the fix belongs here),
  **552** (spec-index commit freshness), 548 (embed + synthesis),
  `plan/issues/research/order-552-real-reembed-cost-measured-2026-08-17.md`

## Summary

`nomic-embed-text` silently truncates input at **~9,750-10,000 characters**
(~2048 tokens, its context window). It returns **HTTP 200 with a valid 768-dim
vector** and no warning of any kind. `tillandsias-plan spec-index` emits chunks
far larger than that, so their embeddings represent only the first ~10k
characters.

**Measured on the real corpus: 11 chunks (0.11%) exceed the limit, and 168,137
characters — 4.6% of the whole corpus — are never embedded at all.**

The loss is not spread evenly. It is concentrated in exactly the documents agents
query most:

| chars never embedded | file |
|---:|---|
| 80,975 | `methodology/distributed-work.yaml` |
| 33,230 | `methodology/multi-host-development.yaml` |
| 14,644 | `methodology/litmus-framework.yaml` |
| 11,742 | `methodology/litmus.yaml` |
| 8,172 | `methodology/agent-observability.yaml` |
| 7,905 | `methodology/proximity.yaml` |

`methodology/distributed-work.yaml` is the canonical source for
`worker_agent_protocol`, `mcp_first_read_path`, `cycle_batch_triage`,
`order_id_allocation` and `long_running_packets`. Its chunk is 90,975 chars;
**~10,000 are embedded and ~80,975 are not.** A `spec_answer` query about the
worker protocol is searching roughly the first 11% of that file.

## Why this is the worst shape of failure

It is not a crash, a refusal, or a `confidence=unsupported`. The pipeline reports
success at every step:

- `spec-index` emits the chunk and counts it — 9,909 chunks, no complaint.
- `/api/embed` returns 200 with a well-formed 768-dimension vector.
- `spec-retrieve` will happily cosine-match against that vector.
- `spec_answer` will return a **cited** envelope pointing at
  `methodology/distributed-work.yaml`.

Every layer is "working". The index simply cannot see most of the file, and
nothing anywhere says so. This is the same class as the `confidence=unsupported`
honesty the project already builds for — except here the system does not know it
is degraded, so it cannot report it.

## How it was established (falsifiable, repeatable)

Truncation is invisible in the response, so it was detected by **vector
identity** rather than by any error signal: if the model truncates at N, then
embedding the full text and embedding its first-N-character prefix must produce
the *same* vector.

```
full chunk (91,224 chars) -> vector hash 898fccf3bb9a8065
prefix    500 chars       -> a23dcd0b98444af0
prefix  1,000 chars       -> a491291b440ee9f5
prefix  2,000 chars       -> 4c143bb7c8899fc3
prefix  4,000 chars       -> 4a4942d39a23a699
prefix  8,000 chars       -> ce1e394f6f739866
prefix 12,000 chars       -> 898fccf3bb9a8065   <-- IDENTICAL to full
prefix 20,000 chars       -> 898fccf3bb9a8065   <-- IDENTICAL to full
```

Bisecting 8,000..12,000: still-changing at 9,750, saturated at 10,000. So the
boundary is **9,750 < B <= 10,000 chars** on this model.

(A first attempt at this test was invalid and is recorded so the method is not
mistrusted: a jq precedence bug — `[.text|length, .path]` parses as
`.text | (length, .path)` and applies `.path` to a string — selected a 17-char
chunk, so all seven prefixes were the same tiny input and "identical" meant
nothing. Correct form is `[(.text|length), .path]`. The numbers above are from
the corrected run.)

## Proposed reduction, with a verifiable closure

The fix belongs in the **chunker (order 547)**, not in the embed step: a chunk
that cannot be embedded whole is not a valid chunk. `spec-index` currently emits
whole top-level YAML blocks regardless of size, which is why the offenders are
all large methodology files.

Verifiable closure — an executable check, not prose:

```
scripts/check-spec-index-chunk-bounds.sh
  -> ok:chunk-bounds:<n>-chunks-max-<chars>
  -> violation:oversized-chunks:<count>   (exit non-zero)
```

It runs `spec-index`, reads back `max(.text|length)`, and fails when any chunk
exceeds the configured embedding context. That closure is cheap (the chunker
takes 5.3 s on the full corpus) and it is falsifiable in the direction that
matters: it fails loudly on exactly the condition that is currently silent.

Two design notes for whoever implements it:

- **The bound belongs to the embedding model, not to a constant.** 9,750-10,000
  chars is `nomic-embed-text`'s 2048-token window measured in this corpus's
  character-to-token ratio. A different embed model moves it. The check should
  take the limit as configuration alongside `TILLANDSIAS_EMBED_MODEL`, and a
  conservative default is better than a tight one.
- **Splitting changes the retrieval unit.** A 90k-char YAML block split into ten
  chunks returns a *section* rather than a whole file, which is arguably better
  for a citation envelope — but it changes what `spec-retrieve --k 6` means, so
  it interacts with 548's synthesis step and should not be treated as a pure
  chunker-internal change.

## Cost context (from the companion filing)

Re-embedding is **free on 96% of commits** and 15-45 s on the 4% that touch the
corpus. Splitting these 11 chunks would add roughly 168,137/10,000 ~= 17 extra
chunks to a 9,909-chunk corpus — about **12 s** of one-time full-rebuild cost out
of ~115 min, and nothing measurable on the delta path. **The fix is
free in performance terms**; the only real cost is the retrieval-unit change
above.
