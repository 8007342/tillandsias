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

**MEASURED AT 3.8B 2026-08-23: channel count buys this tier nothing.** The
earlier text below said the question was untestable here; it is now answered.

| | 0.5B | 3.8B | ratio vs single-channel |
|---|---|---|---|
| pirria, DUAL-channel | 41.0 tok/s (16.4 GB/s) | 8.49 tok/s (18.7 GB/s) | — |
| esmeraldinha, SINGLE | 29.6 tok/s (11.9 GB/s) | 6.53 tok/s (14.4 GB/s) | 1.38x → **1.30x** |

The ratio is **flat across an 8x model-size range**, and the single-channel host
is still at only **67% of its own ~21.3 GB/s ceiling** at 3.8B. A bus-bound
difference WIDENS with model size; this does not. Each host plateaus at a roughly
constant achieved throughput (~16-19 GB/s here, ~12-14 there) whatever the model
size — the signature of a core/latency limit, not a width limit. **Do not prefer a
dual-channel low-end host on bandwidth grounds.**

**A 0.5B model does NOT saturate even a single DDR4 channel**, so do not predict
decode from channel count at this size. Measured 2026-08-23 against the N100
cousin: 41 tok/s x 0.40 GB/token-pass = 16.3 GB/s here, and 29.6 x 0.40 =
11.8 GB/s there — 55% of that host's ~21.3 GB/s ceiling. Neither is bus-limited,
and the dual-channel host is only 1.38x faster, not the ~2x a bandwidth story
predicts. Channel count starts to matter around 3-4B, which the pinned image
cannot run (849-tz8g), so on this tier it is currently **untestable**. Read the
channel count anyway — it bounds the larger models you cannot yet run:

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

**THE ONE QUESTION THAT DECIDES THIS BUDGET**, and it is a design choice rather than
a hardware fact. The same sub-query costs **~1.5 s** without the retrieved evidence
in the prompt and **~40 s** with k=6 evidence prefilled — the evidence is ~96% of the
cost. esmeraldinha independently measured ~2.3 s/sub-query on the same tier and its
number is right for the shape it measured; the two disagree by 17x purely because one
includes the evidence prefill and the other does not. So 853-6gz3's floor is not one
number: it is ~1.5-2.3 s per sub-query if verification is DETERMINISTIC (citation
checking, its Tier A), and ~40 s if the model must re-read the passage to judge it.
On this tier that choice is the difference between a usable layer and an unusable one.

**UPDATE 2026-08-23, after macuahuitl's Tier B result redirected the design.** That
measurement concluded `k=1 is the bottleneck — unfold the question, retrieve per
sub-query, judge each, accumulate`, so the k=6 figure above is superseded by a
change in the DESIGN, not corrected as an error. Re-costed at k=1 here:

| judge call shape | evidence | wall |
|---|---|---|
| k=1 (one retrieved chunk) | ~380 tok | **~4.3 s** |
| k=6 | ~2800 tok | ~40 s |

So a complement pair is ~8.6 s and **30 s buys ~3 sub-queries, 60 s ~7**. The
fan-out this tier can afford is modest but real.

**A BIGGER JUDGE IS NOT THE FIX — measured at 0.5B, 3.8B and 7B, 2026-08-23.**

| judge | in-corpus | out-of-corpus | k=1 call | complement pair |
|---|---|---|---|---|
| qwen2.5:0.5b | YES/NO coherent | NO/NO contradiction | ~4.3 s | 8.6 s |
| phi3.5:3.8b | YES/YES contradiction | NO/NO contradiction | ~26.5 s | 53 s |
| qwen2.5:7b | YES/YES contradiction | NO/NO contradiction | **~41 s** | **82 s** |

**Two separate results, and do not confuse them.**

*On capability*: at n=10 per model THE COMPLEMENT PROBE DISCRIMINATES, AND 7B
IS STRICTLY WORSE — qwen2.5:0.5b sound 5/10 (contradiction 4, inverted 1),
qwen2.5:7b sound 0/10 (contradiction 9, inverted 1); measured by pirria
2026-08-24, temperature 0, five pairs × both framings (ef0ef1a05,
scripts/probe-complement-selfcheck.sh). The shared failure mode is specific:
on passages that do NOT answer, both models answer "is this passage ABOUT X"
instead of processing the negation in "is the passage MISSING the answer";
0.5B at least gets the affirmative framing right on all five, 7B gets nothing
right.

THIS SHEET'S OWN HISTORY ON THE QUESTION, kept because the pattern is the
lesson: cycle 5 inferred a capability "cliff" above 3.8B from one pair
(withdrawn); a later revision declared the probe "degenerate at every size —
measuring the prompt, not the model" from n=1 (ALSO withdrawn — at n=10 the
sizes separate cleanly). Both wrong conclusions came from sample sizes too
small to see the separation. The direction agrees with the fleet's other
measurements — macuahuitl's Tier B caught 17 self-contradictions in 73
questions with this same 7B, and 824-6qxh found bigger embedders separate
monotonically worse — so in this system, bigger is not better; but the probe
is an instrument, not noise.

*On cost*: this is solid and independent of the probe. A 7B judge RUNS here —
5.06 GB resident on 16 GB, 4.56 tok/s decode, `size_vram=0` — but one complement
pair costs ~82 s. **The commodity-hardware claim holds for the machine and fails
for the latency**, at any judge size worth trusting.

**LATENCY IS NOT WHAT BLOCKS THE LAYER HERE.** Running 853-6gz3's own complement
self-check against the only judge this tier can run (`qwen2.5:0.5b`, the image
ceiling of 849-tz8g):

| passage | "does it answer?" | "is it MISSING the answer?" | verdict |
|---|---|---|---|
| one that DOES answer | YES | NO | coherent |
| a CSS passage that does NOT | NO | NO | **self-contradiction** |

The judge is coherent on the in-corpus case and contradicts itself on the
out-of-corpus one — which is exactly the case the layer exists to handle (821-73es:
the expert cannot refuse an out-of-corpus question). The complement mechanism
CATCHES it, which is the mechanism working as designed; but a layer whose judge is
untrustworthy where it matters must refuse rather than answer. **On this tier
853-6gz3 is gated by judge CAPABILITY, not by throughput** — and that is 849-tz8g.

## Use the shared harness for any cross-host claim

`scripts/bench-inference-floor.sh` is the fleet's producer. Run it rather than
hand-rolling, because a ratio is only meaningful when BOTH sides used the same
harness:

```bash
BENCH_ENDPOINT=http://127.0.0.1:11434 BENCH_ENGINE_LABEL=cpu-silverblue-native \
  BENCH_MODELS="qwen2.5:0.5b=T0" scripts/bench-inference-floor.sh
```

Measured here 2026-08-23 (engine=cpu, offload_pct=0, verified via /api/ps):

| | pirria (N150, native) | esmeraldinha (N100, WSL2) |
|---|---|---|
| prefill, ollama HTTP | 123.27 / 146.24 tok/s | ~125 |
| decode, 200 tok | 37.03 / 39.08 tok/s | 28.99-29.64 |
| embed, 250-char chunk | 339.8 ms | 437.3 ms |

**Prefill is indistinguishable between the two hosts; decode is reliably ~1.3x.**
Two back-to-back harness runs here returned prefill 123.27 and 146.24 — a ~19%
run-to-run spread that is WIDER than the within-run range each reports
(115-127, 146-155). Do not read a prefill ratio finer than that spread from a
single run.

**The mechanism behind decode's ~1.3x is NOT established.** Memory bandwidth is
ruled out at this model size by the arithmetic above (neither host saturates a
channel). The remaining candidates are DRAM data rate and sustained all-core
clock, neither of which this host can read without root. Do not attribute it.

**A cautionary history, because this ratio was computed three times before it was
right.** Comparing one host's careful number against another host's careful number
is not a ratio if the two used different methods: the same pair of hosts yielded
"prefill identical", then "1.22x", then "indistinguishable" — the first from a
warm-cache harness figure, the second from two different methods, the third from
one shared harness on both sides. Only the third is worth anything.

## Running a larger model on Silverblue

The shared model cache is a host bind mount, and the pinned image runs as uid
1000. Both of these are needed or the container exits 126 with a bare
"Permission denied" that reads as a broken image:

```bash
podman run -d --userns=keep-id:uid=1000,gid=1000 --security-opt label=disable \
  --env http_proxy= --env https_proxy= --env no_proxy='*' \
  -p 127.0.0.1:11434:11434 \
  -v ~/.cache/tillandsias/models:/home/ollama/.ollama/models \
  --entrypoint /home/ollama/.ollama/models/.tools/ollama/ollama \
  localhost/tillandsias-inference:<tag> serve
```

`--userns` because rootless podman otherwise maps host uid 1000 to container 0;
`label=disable` because SELinux is Enforcing and denies exec from the bind mount.
Clearing the proxy env matters too: the image bakes `http_proxy=http://proxy:3128`,
and when the proxy container is down every pull returns 000 — which looks like
"no egress" and is really "dead proxy".

That symptom is current; the cause below is not. Until 998-3z6g the CA bundle
lived in `/tmp/tillandsias-ca`, so a reboot wiped it and the proxy was left
permanently unrestartable — podman records a bind SOURCE at container creation,
so restarting could not recover it (975-rsgm). The bundle is HOME-relative now
and survives a reboot, so a dead proxy today needs a different explanation.

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

Measured at esmeraldinha's OWN shapes on 2026-08-23 so these are ratios, not two
different experiments. The earlier version of this table compared against figures
that 858-ihcb has since shown were taken over a warm prompt cache (prefill) or
under different conditions (decode); it is corrected here.

| metric (matched conditions) | this host | esmeraldinha (N100, WSL2, single-ch) | ratio |
|---|---|---|---|
| prefill 0.5B, controlled | 107.5 tok/s | 88.3 tok/s | **1.22x** |
| decode 0.5B | ~41 tok/s | 29.64 tok/s | **1.38x** |
| embed, 2000-char chunk | 2215 ms | 2451.5 ms | **1.11x** |
| embed, 250-char chunk | 312 ms | 437.3 ms | **1.40x** |
| query embed | 238 ms | 440 ms | **1.85x** |
| one unfold-and-verify sub-query | ~1.5 s | ~2.3 s | **1.53x** |
| batch of 64 chunks | 105.0 s | — | vs macuahuitl 1.52 s (**69x**) |

**The two ADL-N hosts are the same machine to within 1.1-1.9x on every lane.**
There is no lane where one is qualitatively different from the other, which is the
useful result: the tier behaves as one tier.

**Fan-out is not strictly serial here.** Two concurrent sub-queries cost 0.82x of
running them back to back (2021 ms vs 2458 ms), where esmeraldinha reports strict
serialisation under `OLLAMA_NUM_PARALLEL=1`. So serialisation is a RUNTIME
CONFIGURATION property, not a property of the tier. It is still nearly serial:
two queries cost ~1.6x one, so fan-out width is close to linear in cost either way.

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
