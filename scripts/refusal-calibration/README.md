# Refusal calibration harness (821-73es / 824-6qxh)

The fat-spec expert answers every question, including ones the corpus cannot
answer. `Confidence::Unsupported` exists but on the RAG path the only thing that
produces it is EMPTY CITATIONS (`answer.rs:524`) — and retrieval always returns
a top-1, so nothing ever refuses.

These scripts measure whether any rule COULD refuse, and test an alternative to
having a rule at all.

## The scripts

| script | does |
| --- | --- |
| `measure-bands.sh` | embed a labelled question set, retrieve top-2, emit TSV |
| `analyze-bands.sh` | turn that TSV into a separability verdict, global and per corpus |
| `inject-negatives.sh` | clone an index and append "declined alternative" chunks |

```bash
IDX=~/.local/share/containers/storage/volumes/tillandsias-spec-index-tillandsias/_data/<generation>
scripts/refusal-calibration/measure-bands.sh \
    --model nomic-embed-text --index-dir "$IDX" \
    --questions scripts/refusal-calibration/questions-smoke.jsonl \
  | scripts/refusal-calibration/analyze-bands.sh
```

Question sets are JSONL: `{"band":"in|near|far","corpus":"…","q":"…"}`.
`near` means a PLAUSIBLE question about this project that the corpus genuinely
cannot answer — that band is the whole difficulty. `far` (including nonsense
like "what is the flibber flobber") is easy and proves little on its own: it
scored 0.5463 against an in-corpus floor of 0.6818, separable by a wide margin.

## What has been measured

**A single global cosine threshold cannot work.** In-corpus floor 0.6818 sits
BELOW near-miss ceiling 0.6889. Reproduced across two index generations.

**Neither can a top1-vs-top2 margin.** In-corpus margins 0.0025–0.1353,
near-miss 0.0007–0.0179: they overlap by 0.0154, WORSE than the raw score's
0.0072. The obvious second idea fails harder than the first.

**Per-corpus thresholds do separate** — methodology by 0.0946, cheatsheets by
0.0209 — because the overlap is BETWEEN corpora, not within one. The cheatsheet
margin is thin and narrowed as near-miss questions were added.

**Negative cases work, and change the problem.** See below.

## `analyze-bands.sh` measures the THRESHOLD hypothesis only

Read its verdict carefully when testing negative cases: it assumes a near-miss
should score LOW. Under the negative-case design a near-miss should score HIGH,
on a chunk that says "we do not do that". Run against an injected index it
reports the overlap getting dramatically WORSE (0.0071 -> 0.1229) while the
system is in fact answering correctly. That is the metric being wrong, not the
system. Score which CHUNK won, not how high it scored.

## The negative-case result

Adding three chunks of truthful "we do not use X" content, measured 2026-08-22
against the 20,776-chunk index with `nomic-embed-text`:

```
                                    before                     after
Helm rollback          0.6889 git-mirror cheatsheet  0.8047 declined-alternatives
docker-compose         0.6528 socket-container-health 0.7045 declined-alternatives
ansible playbook       0.6646 distributed-work.yaml   0.6646 distributed-work.yaml
"flibber flobber"      0.5463 nix-flake-basics        0.5463 nix-flake-basics
sourdough bread        0.5676 a spec                  0.5676 a spec

out-of-corpus correctly refused   0/5  ->  2/5
in-corpus unharmed                5/5  ->  5/5   (identical chunks, identical scores)
```

**Why the two that worked, worked.** Cosine similarity is TOPICAL. A chunk that
talks about Helm out-competes a git-mirror cheatsheet on a Helm question. The
retrieved chunk then says, truthfully, that this project does not use Helm —
which is a BETTER answer than a refusal, because it is a fact rather than a
withholding.

**Why the other three did not.** `refusal.sentinel_generic` — the literal "when
you don't know, say you don't know" chunk — never wins anything, because it has
no topic to be similar TO. The ansible question failed even though the injected
chunk names Ansible: one sentence inside a chunk about five other tools does not
move the chunk's embedding enough. Coverage is per-topic and must be earned per
topic.

**So this is not a general refusal mechanism.** It converts ANTICIPATED
near-misses into correct answers. That is worth a great deal — the near-misses
that matter are the plausible ones (Helm, Compose, Ansible, Terraform, systemd),
which is exactly the anticipatable set — but "what is the flibber flobber?" is
untouched by it and still needs either a threshold or a judge stage. Nonsense is
the easy case for a threshold, so the two approaches are complementary rather
than competing.

**And the content is owed anyway.** The project HAS declined these alternatives
deliberately; the corpus is simply silent about the declining. A silent
non-choice is indistinguishable from an oversight, to a reader and to a
retriever alike. `CORPUS_DECLINED` in `spec.rs` already applies this principle
to corpus boundaries — this extends it to technology choices.

## Model size is NOT the ceiling — concurrent residency is (849-tz8g, corrected)

**This section previously claimed the inference image "cannot run the larger
embedders" and tabulated mxbai-embed-large, qwen3-embedding:4b and batched
bge-m3 as aborting. That was wrong, and I filed the packet that was wrong.**
The aborts were real but the cause was misattributed: every one of those loads
happened while another model was already resident. There is no size ceiling.

| model | params | result |
| --- | --- | --- |
| nomic-embed-text | 137M | works, 768-dim, 28 ms/embed, batches of 64 |
| mxbai-embed-large | 334M | works |
| bge-m3 | 567M | works, including batched |
| qwen3-embedding:4b | 4.0B | works, 2560-dim |
| qwen2.5:7b | 7B | works (judge model for Tier B) |

The real defect is **concurrent runner residency**: with ~7,910 MiB resident
across two models, loading a third dies with `GGML_ASSERT` while sixteen
gigabytes are still free. The failure names memory and is not about memory,
which is why it read as a size limit for as long as it did.

**Workaround, proven:** serialise the loads and unload between models.
`measure-recall-at-k.sh` demonstrates it rather than describing it — phase 1
embeds and unloads, phase 2 judges.

Why this correction is loud rather than a quiet edit: a low-end host reading
the old table would conclude its hardware was the limit and stop, when the
actual constraint is a scheduling discipline that costs nothing to adopt. An
inference benchmark filed without concurrent VRAM and utilisation alongside it
is unfalsifiable for exactly this reason — record both, every time.

## Separating retrieval recall from judge quality (2026-08-23)

Tier B at k=1 reported 20% in-corpus support and that number conflated two
things. Measured separately over `results-recall-at-5-qwen7b.tsv`
(73 questions, judge `qwen2.5:7b`, GPU at 1% / 2910 MiB — quiet):

| band | n | recall@1 | recall@5 | lift |
| --- | --- | --- | --- | --- |
| in | 40 | 22.5% | 50.0% | +27.5 pp |
| near | 33 | 0.0% | 0.0% | 0.0 |

Looking past top-1 **doubles** in-corpus support detection — 11 of 40 questions
have a supporting passage in the top 5 that top-1 missed. And the refusal side
does not degrade: five chances to claim support for an unanswerable question
still produced **zero** false positives, 33/33. Widening k is free.

So the judge was never the weak component; `recall@1` was wearing its label.
recall@5 at 50% means the remaining loss is retrieval, which is what makes a
bigger embedder the next move rather than more judge work.
