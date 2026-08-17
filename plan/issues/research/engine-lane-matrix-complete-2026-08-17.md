# The full engine x lane matrix: the LANE matters ~30x more than the ENGINE — and `-ngl 0` is not an off switch

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 6)
- status: measured; completes the CPU+Vulkan rows for 482b/482c
- related: **482b** (llama-server-vulkan-image-variant, ready+unbuilt),
  **482c** (engine-parity-smoke), 482a (engine-slot abstraction),
  482d (one declarative T0-T5 table consumed by both engines),
  410/481 (unmeasured engine lanes),
  `plan/issues/research/engine-parity-ollama-vs-llamacpp-2026-08-17.md` (the CPU row)

## The matrix

All four cells use the **byte-identical GGUF blob**
(`sha256-c5396e06...0515`, 397,807,936 bytes, `qwen2.5:0.5b`) resolved from the
ollama manifest. 4 threads, `n_ctx` 4096, 1 slot, f16 KV, no flash attention.
Prompt caching defeated with a per-run nonce in every cell.

| engine | lane | prefill tok/s | generation tok/s |
|---|---|---:|---:|
| ollama | CPU | 90.57 - 92.03 | 26.44 - 30.20 |
| llama.cpp | CPU | 84.90 - 85.95 | 28.63 - 30.02 |
| ollama | Vulkan iGPU | ~296 | ~20 |
| llama.cpp | Vulkan iGPU (`-ngl 99`) | 267.30 - 284.37 | 19.03 - 19.12 |

### Two conclusions

**1. Engine parity holds on BOTH lanes.** CPU: within ~6%. Vulkan: llama.cpp is
~5-10% under ollama on prefill (267-284 vs ~296) and identical on generation
(19.1 vs ~20). Ollama wraps llama.cpp and the wrapper costs almost nothing on
either lane.

**2. The lane dominates the engine by more than an order of magnitude.**

| switching... | changes prefill by | changes generation by |
|---|---|---|
| **lane** (CPU <-> Vulkan) | **~3.3x** | **~35%** |
| **engine** (ollama <-> llama.cpp) | <=10% | <=6% |

So `482a`'s engine slot is the *less* consequential of the two axes it exposes,
and `482d`'s shared T0-T5 table is right to be engine-agnostic: what it needs is
a **lane** dimension, not an engine one. A host that picks the wrong lane loses
3x; a host that picks the "wrong" engine loses noise.

## `-ngl 0` is NOT a clean off switch — the negative control that failed

The obvious negative control for "is Vulkan doing the work?" is to re-run the
identical server with `-ngl 0`. It **did not revert**:

| llama.cpp configuration | prefill tok/s | generation tok/s |
|---|---:|---:|
| Vulkan backend loaded, `-ngl 99` | 267 - 284 | 19.0 - 19.1 |
| Vulkan backend loaded, **`-ngl 0`** | **165 - 241 (variable)** | 28.8 - 29.5 |
| **Vulkan backend not loaded at all** | **84.9 - 86.0** | 28.6 - 30.0 |

Generation reverted cleanly (29 ~= CPU). Prefill did not: with zero layers
offloaded it still ran 2-2.8x the true CPU baseline, and with unusually wide
run-to-run spread.

**Explanation: `-ngl` controls WEIGHT offload, not op scheduling.** Once the
Vulkan backend is *registered*, ggml's graph scheduler may place operations on
it regardless of where the weights live, paying host<->device transfers for
them. Prefill is compute-dense enough to win anyway; generation is not, so it
falls back to CPU-like numbers. The variance is the transfer cost showing
through.

The clean control is **not loading the backend at all** (`GGML_BACKEND_PATH`
unset and the vulkan directory off `PATH`), which reproduces 84.9-86.0 across
five runs — matching the independently measured 85.73-87.50 from the previous
cycle.

### Why this matters beyond this measurement

Any future litmus or probe that asserts "this run was CPU-only" by passing
`-ngl 0` **will be wrong**, and wrong in the flattering direction: it will
record CPU numbers that are silently 2x too fast. The falsifiable test is
backend *presence*, not layer count. For ollama the equivalent is
`OLLAMA_IGPU_ENABLE`, and the check remains reading back `size_vram` from
`/api/ps` rather than trusting a flag — the order-392 rule, which this host has
now violated once and caught once.

## Method note: the log could not answer, so the measurement did

The bundled `llama-server` (version `1 (0b1bad14f)`) does not emit the upstream
`system_info` / `load_backend` lines under `Start-Process` stderr redirection, so
**there was no log line stating which backend was active.** Rather than assume,
backend engagement was established by measurement against two independently
reproduced baselines (CPU ~85, ollama-Vulkan ~296). That is weaker evidence than
a log line and is recorded as such — but it is falsifiable, repeatable, and it
is what was actually available.

A first attempt to load the backend also failed instructively:
`GGML_BACKEND_PATH` must name the **DLL file**, not its directory
(`failed to load ...\lib\ollama\vulkan:`). Pointing it at
`vulkan\ggml-vulkan.dll` works.

## Residual

- **Not measured**: the matrix above T0. Parity at 0.5B does not entail parity at
  3.8B, where memory-bandwidth pressure is far higher and the lane gap may widen
  or invert.
- **Not measured**: embeddings on llama.cpp. The one workload where the iGPU
  clearly *loses* (`nomic-embed-text` 137M, 58% slower on Vulkan) was only
  measured on ollama.
- The `-ngl 0` scheduling behaviour was inferred from timings, not read from
  ggml's scheduler. The inference is consistent and reproducible, but a source
  read would settle it.
