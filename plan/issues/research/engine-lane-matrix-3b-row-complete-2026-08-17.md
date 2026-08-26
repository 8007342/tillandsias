# The 3.8B row completes the matrix: the decode crossover does NOT exist on 24 EUs, and by the time it would, both lanes are unusable

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 13)
- status: measured; closes the last residual of the engine x lane x size matrix
- related: **793-zumy** (Yolanda's AMD dzn measurement — its decode-crossover
  finding is shown here to be hardware-class dependent),
  `intel-igpu-dzn-in-wsl2-measured-2026-08-17.md`,
  `engine-lane-matrix-complete-2026-08-17.md`,
  `accel-capability-envelope-and-routing-2026-08-16.md` (the routing consumer),
  410/481/482, 522

## Result

`phi3.5:3.8b` (Q4_K_M) in `tillandsias-build`, two interleaved reps per lane,
unique prompt per rep, offload verified per arm (`cpu vram=0 / 0%`,
`dzn vram == size / 100%`):

| lane | prefill tok/s | decode tok/s |
|---|---|---|
| CPU | 13.84 / 16.99 | 5.93 / 6.26 |
| dzn iGPU | 31.57 / 27.55 | 3.63 / 3.65 |
| **ratio** | **GPU 1.92x** | **CPU 1.68x** |

## The matrix, complete

| model | prefill | decode |
|---|---|---|
| `qwen2.5:0.5b` | GPU **2.16x** | CPU **1.88x** |
| `phi3.5:3.8b` | GPU **1.92x** | CPU **1.68x** |
| `nomic-embed-text` (embedding, prefill-only) | GPU **1.27x** | — |

**The direction never changes across an 8x range of model size.** The iGPU wins
compute-bound work (prefill, embeddings) and loses bandwidth-bound work (decode)
at every size measured.

## The decode crossover is hardware-class dependent — this is the floor host's answer

793-zumy found, on an AMD Radeon 860M (RDNA 3.5), that decode **crosses over to
the GPU by 3B** (CPU 1.23x ahead at 0.5B, GPU 1.38x ahead at 3B), and reasoned
that the fixed per-dispatch cost dominates at small sizes and is absorbed by the
arithmetic at larger ones. That reasoning is sound and their measurement stands.

**It does not generalise to this part.** On 24 EUs:

| | 0.5B | 3.8B | trend |
|---|---|---|---|
| decode advantage | CPU 1.88x | CPU 1.68x | shrinking, but **never crosses** |

The penalty is trending the way their model predicts — 1.88 -> 1.68 — but it has
not crossed by 3.8B, which is already past the size where their part crossed.
Extrapolating the trend, a crossover would land well above 3.8B.

**And that is the finding that matters, because it is self-cancelling**: at 3.8B
the dzn decode rate is already **3.6 tok/s**. By the model size where this iGPU
might win decode, both lanes are far too slow for any interactive use. **On this
class of part the decode crossover is unreachable in practice, not merely
distant.**

So a routing policy of the form "GPU for decode above N parameters" — which
793-zumy's data alone would support — is **wrong on this hardware for every
usable N**. The safe policy across both measured parts is the workload-shape
rule, which needs no size threshold at all:

> **Prefill-shaped work (prompt processing, embeddings) to the iGPU;
> decode-shaped work to the CPU.**

That rule is correct on AMD 860M at 0.5B, correct on Intel UHD at 0.5B and 3.8B,
and correct for embeddings on both. The only case it gets "wrong" is AMD decode
at 3B, where it forgoes a 1.38x win — a conservative error, not a regression.

## Why a size threshold is the wrong shape for this policy

A threshold has to be tuned per part, and getting it wrong is asymmetric:

- Too low on this host: routes 3.8B decode to the iGPU, a **1.68x slowdown**.
- Too high on Yolanda's host: forgoes a 1.38x speedup — costs nothing, just
  leaves value on the table.

Since the fleet must "support all different hardware configurations dynamically
and pick whichever performs better" (operator, 2026-08-16), and since the parts
disagree about where the threshold sits, the robust default is the shape rule
plus **per-host measurement** where a host wants the extra decode win. The
harnesses to do that measurement are committed (`bench-inference-floor.sh`,
`bench-semantic-budget.sh`) and both hosts now have comparable numbers from them.

## Absolute numbers for the floor (expectation-setting)

`phi3.5:3.8b` on this host is **not usable interactively on either lane**:
6.1 tok/s decode on CPU, 3.6 on the iGPU. Prefill of a 3,000-token RAG context
costs ~195 s on CPU or ~101 s on the iGPU. Combined with the cycle-2 finding that
no model meets `semantic_expert.rs`'s 1500 ms budget, T2 has no role on this host
regardless of lane.

## Caveats

- Two reps per lane, not three. CPU prefill showed the widest spread
  (13.84 / 16.99, ~20%); the decode figures were tight on both lanes
  (5.93/6.26 and 3.63/3.65) and it is decode that carries the conclusion.
- The `-ngl 0` trap from cycle 6 does not apply here: the CPU arm was run with
  `OLLAMA_VULKAN=0` and no backend loaded, and read back `vram=0`.
- Not measured: llama.cpp directly at 3.8B. Engine parity was established at
  0.5B on both lanes (<=10%) and there is no mechanism proposed by which a
  wrapper would diverge at larger sizes, but it is an assumption rather than a
  measurement.
