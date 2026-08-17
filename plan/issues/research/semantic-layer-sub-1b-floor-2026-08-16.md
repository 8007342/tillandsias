# The sub-1B floor: no model that answers correctly meets `semantic_expert`'s 1500 ms budget on the lower-bound host — and that is fine

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 4)
- status: measured; recommends a default, does not change one
- related: order 393 (signed construction decision — deterministic engine at
  0.02 s/query, model ruled STRICTLY WORSE for ledger queries), 391
  (forge-local-experts-milestone), 718-nkm2 / 718-rtnh (bare-metal expert
  inference parity), `crates/tillandsias-plan/src/semantic_expert.rs`

## The question

Operator directive 2026-08-16: the architecture is RAG plus a thin semantic
interpretation layer — *decomposition instead of a larger model* — so the
question for the floor host is not "how big can we go" but **how small can we go
and still work**.

## What the code actually asks for

`semantic_expert.rs` is stricter than it first appears:

- **prompt shape** (`:357`): ``Based on this excerpt from '{title}':\n\n{content}\n\nQuestion: {q}\nAnswer concisely:``
- **`stream: false` and NO `num_predict` cap** (`:305-310`) — the model runs
  until it decides to stop.
- **the 1500 ms is a SOCKET READ TIMEOUT** (`:250`, `:303`), not a soft budget.
  The COMPLETE response must arrive inside it.
- **on timeout it returns `None`**, and the caller (`:369`) silently falls back
  to `section.content` — the raw retrieved excerpt.

So the pass condition is total wall clock < 1500 ms, and failure is silent
degradation rather than an error.

## Correction to an earlier estimate (recorded because it changed the framing)

An earlier note in this cycle projected that "even 0.5B blows the budget on
prefill alone — 2.75 s for a 300-token section", extrapolating from a measured
T0 prefill of 108.9 tok/s.

**That was wrong by roughly 10×.** Measured directly: `qwen2.5:0.5b` prefills
**528 prompt tokens in 453 ms (~1165 tok/s)**.

The 108.9 tok/s figure came from an **82-token** prompt, where fixed per-call
overhead dominates the rate. Prefill batches well, so a rate derived from a tiny
prompt understates a realistic one badly. **Prefill is not the bottleneck** — it
ranged 31-459 ms across every model measured.

The general lesson is worth more than the number: a throughput figure taken at
one input size must not be extrapolated to another without saying so.

## Measurement 1 — uncapped, as the code runs today

Real plan section (`plan/loop_status.md:6731-6760`, the Direction), 1722 chars;
prompt 1853 chars. 2 reps, warm.

| Model | verdict | avg ms | prompt tok | eval tok |
|---|---|---:|---:|---:|
| `smollm2:135m` | PASS | 842 | 578 | **9** |
| `gemma3:270m` | PASS | 886 | 531 | **1** |
| `smollm2:360m` | FAIL | 2885 | 578 | 51 |
| `qwen3:0.6b` | FAIL | 21157 | 509 | 287 |
| `tinyllama:1.1b` | FAIL | 17897 | 642 | 203 |

**Both "PASS" verdicts are artifacts.** `gemma3:270m` met the budget by emitting
**one token**. A pass earned by not answering is a measurement bug, not a
result — which is why `eval_tok` belongs in the grammar next to the verdict.

`qwen3:0.6b` at 21 s is the unbounded-generation failure mode in its purest
form: it is a reasoning model, and with no `num_predict` it spends 287 tokens
thinking.

## Measurement 2 — capped at `num_predict: 64`, with answer quality

| Model | total ms | verdict | prefill ms | gen ms | eval tok | answer |
|---|---:|---|---:|---:|---:|---|
| `smollm2:135m` | 1470 | PASS | 31 | 1048 | 42 | **hallucinated** — invented a "FAST-TILANDERS project" |
| `gemma3:270m` | 1274 | PASS | 139 | 360 | 8 | **empty** — "We are all doing today:" |
| `smollm2:360m` | 4046 | FAIL | 66 | 3604 | 64 | **correct** |
| `qwen2.5:0.5b` | 2508 | FAIL | 459 | 1378 | 27 | **correct**, quotes the Direction accurately |
| `qwen3:0.6b` | 5134 | FAIL | 92 | 4347 | 64 | empty (thinking tokens) |
| `tinyllama:1.1b` | 4959 | FAIL | 95 | 4452 | 64 | echoes the prompt back |

**Speed and correctness are inversely ordered.** Everything fast enough is
wrong; everything correct is too slow. There is no crossing point in this range.

## Measurement 3 — can a tighter cap rescue the best candidate?

`qwen2.5:0.5b` is the only model that both answers correctly and lands near
budget. Sweeping its cap:

| `num_predict` | total ms | verdict | prefill ms | gen ms |
|---:|---:|---|---:|---:|
| 12 | 1673 | FAIL | 453 | 589 |
| 16 | 1924 | FAIL | 484 | 803 |
| 24 | 1890 | FAIL | 73 | 1223 |
| 32 | 2279 | FAIL | 60 | 1640 |

**Even a 12-token answer does not fit.** At that point the response is
"We're giving forge agents local EXPERTS, focusing on" — truncated mid-sentence
and still 1673 ms.

### Two incidental findings from this table

- **Prompt caching is real and large.** Prefill fell from 453/484 ms to 73/60 ms
  once the identical prompt repeated. The semantic expert's prompts vary by
  section and question, so it would normally pay the cold figure — but a
  repeated-question workload gets a 6-8x prefill discount for free.
- **~630 ms of per-call overhead exists outside prefill and generation.** At
  `num_predict=12`: 453 prefill + 589 generation = 1042 ms of accounted work
  against 1673 ms of wall clock. No cap can remove that residue; it bounds any
  budget this host can ever meet.

## Conclusion, and the recommendation

**On the lower-bound host, no model that answers correctly meets the 1500 ms
budget, at any cap.** The models that meet it hallucinate or emit nothing.

This is not a failure of the architecture. `semantic_expert.rs:369` already
degrades to the raw retrieved excerpt on timeout, and order 393's signed
decision already measured the deterministic engine at **0.02 s/query, 12.5 MB
RSS** and ruled a model *strictly worse* for ledger queries.

So the recommendation for floor-class hosts is: **leave the semantic layer OFF
by default and let RAG retrieval answer.** Not "tune it smaller."

**The decomposition proof-of-concept holds — but for a better reason than the
one we set out to prove.** It does not hold because a tiny model is fast enough;
at this hardware level none is. It holds because retrieval alone answers well
and the semantic layer is genuinely optional. A design whose expensive tier can
be removed without losing the answer is stronger evidence for decomposition than
one whose expensive tier merely runs quickly.

## Residuals (not closed here)

- **No `num_predict` in `semantic_expert.rs`.** Unbounded generation is what
  turns a 1.4 s call into a 21 s one on a reasoning model. Even if the layer is
  off by default here, any host that enables it wants a cap. Small, isolated.
- **A budget that cannot be met produces silent degradation.** Every query on
  this host would time out and fall back, indistinguishably from a host with no
  model configured. Worth a typed signal so "degraded because too slow" is
  visible rather than inferred — the same fail-loud argument as the MCP health
  probe (737-zcj5).
- **Not measured**: llama.cpp directly (order 482c parity evidence), the WSL2
  CPU lane which is the user-representative configuration, and whether the
  Vulkan iGPU changes any of this (it should not — these are sub-1B models,
  below the crossover measured in
  `esmeraldinha-lower-bound-inference-floor-2026-08-16.md`, where the iGPU
  loses).
- `qwen2.5:0.5b` reported `ERROR=unavailable` on the uncapped run only, after a
  bulk unload; it worked in every capped run. Not chased — noted so a future
  reader does not treat that one cell as data.
