# Order 482c parity evidence: on CPU, Ollama and llama.cpp are the same speed — and a correction to the iGPU crossover claim

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 5)
- status: measured; supplies 482c's parity evidence and **corrects** a claim
  filed by this host in cycle 1
- related: **482c** (llama-server-engine-parity-smoke — this is its evidence),
  482a (engine-slot abstraction), 482b (vulkan llama-server image variant),
  482d (one declarative T0-T5 table consumed by BOTH engines),
  410/481 (unmeasured engine lanes),
  `plan/issues/esmeraldinha-lower-bound-inference-floor-2026-08-16.md` (corrected here)

## Method — why this comparison is apples-to-apples

Ollama bundles `llama-server` and stores model weights as plain GGUF blobs, so
**both engines were run on the byte-identical file**:

```
~/.ollama/models/blobs/sha256-c5396e06...0515   (397,807,936 bytes, qwen2.5:0.5b)
```

resolved from the Ollama manifest's `application/vnd.ollama.image.model` layer.
No re-download, no requantisation, no version skew — the only variable is the
engine.

Controls applied, each because an earlier draft of this measurement was wrong
without it:

1. **Cache defeated.** A unique nonce is embedded in every prompt. Without it,
   Ollama reported a prefill of **9916 tok/s** — physically impossible on a
   21.3 GB/s single-channel host — because it was serving a cached prefill from
   the warm-up. llama.cpp was already honest here (`cache_prompt:false`), so
   comparing the two directly would have been meaningless in Ollama's favour.
2. **Offload verified, not assumed.** `/api/ps` is read after warm-up and
   `size_vram` must be 0 for a CPU-lane run. This matters enormously — see the
   confound below.
3. **Settings matched**: 4 threads, `n_ctx` 4096, 1 slot/parallel, f16 KV, no
   flash attention — Ollama's `cpu` tier policy from `engine-tuning.sh`.
4. Three runs per engine, reported as ranges rather than means.

## Result — parity

| CPU lane, qwen2.5:0.5b | prefill tok/s | generation tok/s |
|---|---:|---:|
| Ollama | 90.57 – 92.03 | 26.44 – 30.20 |
| llama.cpp (`llama-server`) | 85.73 – 87.50 | 28.34 – 28.59 |

**Within ~6% on prefill and within run-to-run noise on generation.** Ollama wraps
llama.cpp, and on this host the wrapper costs approximately nothing.

That is a boring result, and boring is the right answer for a parity smoke: it
means 482a's engine-slot abstraction can treat the two as interchangeable on the
CPU tier, and 482d's shared T0-T5 table does not need per-engine throughput
columns for CPU.

### A tuning hypothesis that failed (recorded so it is not re-tried)

Before the offload confound was caught, llama.cpp appeared to prefill 3.5x
slower, and the natural hypothesis was that Ollama uses a larger prefill batch —
a knob Ollama does not expose. Tested: `-b 2048 -ub 2048` versus the defaults
gave **85.55-87.50 tok/s against 83.62-84.91** — inside noise. Batch size is not
the lever. (The real cause was that Ollama was on the iGPU; see below.)

## The confound that nearly produced a false finding

The first comparison read Ollama at 296 tok/s prefill against llama.cpp's 84 and
would have been published as "Ollama prefills 3.5x faster." It was wrong:
`OLLAMA_IGPU_ENABLE=1` was still set from cycle 4, and `/api/ps` showed
`size_vram == size`, i.e. **pct_on_gpu=100%**. The measurement was
*Ollama-on-Vulkan-iGPU versus llama.cpp-on-CPU* — not an engine comparison at
all.

This is precisely the failure `scripts/bench-inference-floor.sh` was written to
prevent, whose header says the engine label must be **derived from `/api/ps`,
never trusted** (the order-392 rule). The ad-hoc comparison above did not use
that harness and reproduced exactly the mistake the harness exists to stop.
**Recorded as a process finding, not just a data point: a one-off measurement
should go through the harness, or it will re-learn the harness's lessons.**

## CORRECTION to cycle 1's crossover claim

`esmeraldinha-lower-bound-inference-floor-2026-08-16.md` reported for T0
(`qwen2.5:0.5b`) a Vulkan prefill of **17.87 tok/s** against a CPU 108.9, and
concluded a **"model-size crossover below ~1B"** — that below roughly 1B
parameters the Vulkan dispatch overhead dominates and the CPU wins.

That filing already flagged the 17.87 figure as suspect ("first model loaded
into a fresh server, so it plausibly includes Vulkan shader/pipeline
compilation... reported, not relied upon"). **It was indeed an artifact.**
Measured warm, with the cache defeated:

| qwen2.5:0.5b | prefill tok/s | generation tok/s |
|---|---:|---:|
| CPU | ~91 | ~28.9 |
| Vulkan iGPU | **~296 (3.2x faster)** | ~20 (~30% slower) |

**So the iGPU wins prefill at 0.5B as well.** The prefill half of the "crossover
below 1B" claim is wrong and is withdrawn.

What survives, restated precisely:

- **The iGPU wins compute-bound prefill and loses bandwidth-bound generation.**
  That pattern now holds at 0.5B, 1.1B and 3.8B — it is not size-gated in the
  range measured.
- **The one genuine loss stands**: `nomic-embed-text` (137M) was 58% *slower* on
  Vulkan (4287 ms/chunk vs 2714). That is a different workload shape — a single
  forward pass with no generation phase — so it is evidence about *embedding*,
  not evidence for a parameter-count threshold. Whether a true crossover exists
  between 137M and 500M is **unmeasured**, and should not be asserted again
  without measuring it.

The general lesson is the same one this host filed about prefill extrapolation:
a number flagged as suspect must not be carried into a conclusion. Cycle 1
labelled the artifact correctly and then built a claim on it anyway.

## Residual

- Not measured: llama.cpp on the **Vulkan** lane. `llama-server` can be built
  with Vulkan and Ollama ships `ggml-vulkan.dll`, so a four-way
  (engine x lane) matrix is reachable and would complete 482b/482c. This cycle
  covered the CPU row only.
- Not measured: engines above T0. Parity at 0.5B does not entail parity at 3.8B,
  where memory-bandwidth pressure is far higher.
- `llama-server`'s own stderr log did not capture the `system_info` backend line
  under `Start-Process` redirection, so **which** ggml CPU variant it loaded
  (this host ships `ggml-cpu-alderlake.dll` among a dozen) is unconfirmed. Ollama's
  runner reports `AVX_VNNI=1 LLAMAFILE=1 REPACK=1`. Given the parity result the
  question is academic for now, but it is the first thing to check if the two
  engines ever diverge on CPU.
