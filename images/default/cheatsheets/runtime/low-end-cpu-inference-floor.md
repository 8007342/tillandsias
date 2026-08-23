---
title: Low-End CPU-Only Inference Floor (Alder Lake-N class)
tags: [inference, cpu, low-end, alder-lake-n, ollama, embeddings, capability-matrix]
languages: [bash]
since: "2026-08-23"
last_verified: "2026-08-23"
sources:
  - https://github.com/ollama/ollama
  - https://github.com/ggml-org/llama.cpp
  - https://containertoolbx.org/
  - https://docs.fedoraproject.org/en-US/fedora-silverblue/
  - https://docs.mesa3d.org/drivers/anv.html
  - https://ark.intel.com/
authority: high
status: current
tier: pull-on-demand
pull_recipe: see-section-pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
---

# Low-End CPU-Only Inference Floor (Alder Lake-N class)

@trace order:855-wrr3, spec:accel-capability-probe

**Version baseline**: tillandsias-inference v0.4.260817.1, ollama 0.32.14
**Use when**: deciding whether a small x86 host can serve the expert layer, hold a
cycle cadence, or build the spec index — and what to expect before you try.

## Quick reference — what a 4-core Alder Lake-N can and cannot do

| Workload | Verdict |
|---|---|
| `qwen2.5:0.5b` chat-shaped answer (~75 tok) | **Yes** — ~2.1 s |
| Embedding a short query (8-24 tok) | **Yes** — 85-155 ms |
| Embedding one 393-token corpus chunk | Marginal — **1.64 s** |
| Full spec-index rebuild (10-20k chunks) | **No** — 4.5-9.4 hours |
| Expert layer fan-out over k=6 (~3000 tok) evidence | **No** at interactive latency |
| Any GPU offload with the pinned image | **No** — CPU ggml backends only |

## The two numbers that govern everything

Measured on Intel N150 (4 ADL-N E-cores, no SMT, AVX_VNNI, dual-channel 16 GB):

- **Prefill / embedding: ~107 tok/s** (generation prefill) and **~230 tok/s** (embedder)
- **Decode: ~39-43 tok/s** on a 0.5B model

Prefill is compute-bound; decode is memory-bandwidth-bound. This is why two hosts
with the *same* ADL-N cores can differ ~2x on decode and not at all on prefill —
the difference is DRAM channels, not cores. Check channel count before predicting
decode:

```bash
for d in /sys/devices/system/edac/mc/mc*/dimm*; do
  echo "$(cat $d/dimm_label) $(cat $d/size)MB"; done
# MC#0_Chan#0_* and MC#0_Chan#1_* both populated => dual channel
```

## Batching does not help on CPU

The single most load-bearing result: embedder throughput is **flat** across batch size.

| batch | ms/embed | tok/s |
|---|---|---|
| 1 | 1752 | 224 |
| 8 | 1598 | 232 |
| 32 | 1642 | 230 |
| 64 | 1641 | 230.8 |

On a GPU a batch of 64 amortizes massively; here it buys nothing, because the cost
is irreducible compute rather than call overhead. **Do not size CPU embedding work
as if batching will rescue it.**

## Commands (reproduce exactly)

```bash
# Embedding — the production call shape (scripts/spec-index-ensure.sh:427)
curl -fsS --max-time 300 http://127.0.0.1:11434/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text","input":["...chunk..."]}'   # .usage.prompt_tokens

# Generation — ollama reports prefill/decode separately; use DISTINCT prompts per
# rep or reps 2+ are served from KV cache and the "prefill" figure is a cache hit.
curl -fsS http://127.0.0.1:11434/api/generate -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:0.5b","prompt":"...","stream":false,
       "options":{"num_predict":64,"temperature":0}}'
# tok/s = eval_count * 1e9 / eval_duration
```

## The expert-layer budget (order 853-6gz3)

A judge call = read the retrieved evidence, emit a short verdict. Measured with
NOVEL text per rep (a reused prefix is served from ollama's KV cache and reports
50,000+ tok/s, which is not a measurement):

| evidence | prefill tok/s | wall per call |
|---|---|---|
| ~430 tok | 95 | 4.9 s |
| ~1150 tok | 118 | 11.0 s |
| **~2800 tok (k=6)** | **72.3** | **~40 s** |

**Prefill throughput falls as context grows** (attention is superlinear), so evidence
size is worse than proportionally expensive. Peak is near ~1000-1500 tokens.

The layer's complement design needs TWO judge calls per sub-question (a claim and
its complement), so on this host:

| fan-out | calls | wall |
|---|---|---|
| n=1, 1 wave | 2 | **~80 s** |
| n=3 | 6 | ~4 min |
| n=5 | 10 | ~6.7 min |

**At k=6 evidence, not one complement pair fits in an interactive answer.** The
governing quantity is EVIDENCE TOKENS, not sub-question count: budget approximately
`tolerable_seconds x prefill_tok_s` across the whole fan-out. To keep one complement
pair under 30 s here you need ~1,500 tokens per call — about k=3, not k=6.

## Common pitfalls

- **Reusing one prompt across reps.** ollama caches the KV prefix, so reps 2+ report
  1670-2125 tok/s "prefill" that never happened. Only a distinct-prefix rep is honest.
- **Reading the EDAC DRAM type.** `igen6_edac` reports `Low-Power-DDR3-RAM` on ADL-N,
  which is wrong. The *channel labels* are trustworthy; the type field is not.
- **Assuming an iGPU is a compute device because `/dev/dri/renderD128` exists.**
  A render node proves a display/media driver, not a compute lane.
- **Assuming an iGPU is useless because it is integrated.** The opposite error. On
  this silicon class Vulkan offload measurably wins *prefill* (+31%/+60%) and loses
  *decode* (-17%/-20%) — see esmeraldinha, plan/loop_status.md:3896.

## Derived notes — measured on this host, not upstream documentation

Per methodology/cheatsheets.yaml the section above is upstream-anchored; everything
in this section is project-local measurement and is labeled as such.

**Cold bootstrap on Fedora Silverblue (measurable once per host)** — 2026-08-23,
Intel N150, `./build.sh --check` from a host with no toolbox, no `~/.cargo`,
no `~/.rustup`, no `target/`:

| phase | wall |
|---|---|
| `toolbox create` (pull fedora-toolbox:44, 2.18 GB) | 23 s |
| dnf toolchain + rustup + 2 musl targets (1.9 GB `~/.rustup`) | 54 s |
| **bootstrap subtotal (pre-cargo)** | **77 s** |
| `cargo check --workspace` + gate phases (cold) | 259 s |
| **`./build.sh --check` total, cold, rc=0** | **336 s (5.6 min)** |
| `cargo build --release` (tillandsias + tillandsias-plan) | 204 s |
| **cold bootstrap to a usable release binary** | **540 s (9 min)** |

Network-dependent: the two download phases above completed on a fast link and will
dominate on a slow one.

Two things this table is often expected to say and does not. (a) The cold cost on
this class of machine is **minutes, not hours** — the fear that a small host cannot
bootstrap is unfounded; what it cannot do is *embed a corpus* (see above).
(b) `./build.sh --check` is `cargo check --workspace` (build.sh:402): it COMPILES
the workspace's unit tests and never RUNS them, so it is not evidence that the
tests pass. On this host one of them does not (order 856-xvr2).

**Cross-host ratios** (same corpus shape, ledger-recorded):

| metric | this host | esmeraldinha (N100, single-channel) | macuahuitl (RTX A5000) |
|---|---|---|---|
| prefill 0.5B | 107.5 tok/s | 108.9 tok/s (**0.99x**) | — |
| decode 0.5B | ~39 tok/s | 20.5 tok/s (**1.9x**) | — |
| embed | 230 tok/s | 176.6 tok/s (**1.30x**) | — |
| batch of 64 chunks | 105.0 s | — | 1.52 s (**69x**) |

**Engine ceiling, not hardware ceiling.** The pinned inference image ships only
`libggml-cpu-*.so`. There is no `libggml-{cuda,hip,sycl,vulkan}.so` in it, so no GPU
can be used regardless of the silicon — while Mesa ANV Vulkan *is* present in the
Silverblue base with no layering. Same shape as 849-tz8g: the image is the ceiling.

## Pull on Demand

### Source

Compact anchor sheet. The measurements below are project-local (see the derived-notes
section); pull the upstream references when tuning an engine or adding an accelerator
lane, not to read the numbers.

- **Upstream URL(s):**
  - `https://github.com/ollama/ollama`
  - `https://github.com/ggml-org/llama.cpp`
  - `https://docs.mesa3d.org/drivers/anv.html`
  - `https://containertoolbx.org/`
- **Archive type:** single-page references
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/low-end-cpu-inference-floor`
- **License:** reference-docs
- **License URL:** `https://opensource.org/license/mit`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/low-end-cpu-inference-floor"
mkdir -p "$TARGET"
cp cheatsheets/runtime/low-end-cpu-inference-floor.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Re-measure before trusting any number here on different silicon — the ratios move
   with memory channel count, not with core count.
2. Use novel text per rep for any prefill measurement; a reused prefix is served from
   ollama's KV cache and reports throughput that never happened.
3. Take no inference measurement while the agent is also running plan queries: on a
   4-core host the agent's own tooling is a competing workload.
