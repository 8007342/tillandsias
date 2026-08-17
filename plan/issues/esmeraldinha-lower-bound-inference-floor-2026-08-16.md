# ESMERALDINHA: first measured inference floor on x86 CPU-only silicon, and the Vulkan iGPU lane retires its "unmeasured" status

- classification: research
- filed: 2026-08-16 (windows/ESMERALDINHA, operator-attended onboarding session)
- status: measured — numbers below are first-of-their-kind for this project;
  a clean (uncontended) re-run is still owed, see "Caveats"
- related packets: 410 / 481 / 482 (unmeasured non-CUDA engine lanes),
  482b (vulkan llama-server image variant, ready, unbuilt),
  402 (windows-inference-tier-verification, ready, `pickup_role: windows` —
  its explicit residual IS the cpu-tier measurement this file supplies),
  552 (spec-index commit freshness), 547 (chunking that enables delta re-embed),
  718-rtnh / 718-nkm2 (bare-metal expert inference parity, WSL2 substrate
  decision), 391 (forge-local-experts-milestone, exit criterion 4)

## Why this host exists

Operator directive 2026-08-16: ESMERALDINHA is the fleet's **lower-bound
hardware reference**. Performance work is routed here because every other host
performs acceptably even unoptimized, so only this one reveals which
optimizations are load-bearing. Scope is **performance packets only** — no
general plan drain.

This is a new mandate. The project had a sibling N100 host (**Esmeralda**,
field-used 2026-08-08/09) which produced the `low-end-hardware` capability tag
and Windows control-wire defect packets, but **no performance mandate ever
existed**: no benchmark harness, no tok/s number on x86 CPU-only silicon, no
Intel iGPU lane, and no way for a host to declare itself the fleet's floor.

## Host profile (measured, not assumed)

| Property | Value |
|---|---|
| CPU | Intel N100 — 4 Alder Lake-N E-cores, **no SMT** |
| RAM | 1 x 16 GB **DDR4-2667**, 64-bit, **single channel** (`Controller0-ChannelA-DIMM0`) |
| Memory bandwidth ceiling | **~21.3 GB/s** theoretical (2667 MT/s x 8 B) |
| GPU | Intel UHD Graphics, 24 EU, Alder Lake-N (`deviceID 0x46d1`), **shares the same bus** |
| Vulkan | 1.4.323, `DRIVER_ID_INTEL_PROPRIETARY_WINDOWS`, driver 101.7088 |
| Disk | 256 GB budget SSD (ShiJi), single NTFS volume |

The N100 is a **single-channel** memory controller by design, so the ~21.3 GB/s
ceiling is not expandable by adding a DIMM. This is also the *low* N100 variant:
LPDDR5-4800 N100 boards reach 38.4 GB/s, nearly double.

**This one number predicts most of what follows.** Token generation is
bandwidth-bound, so a model's weights-in-bytes divided by ~21.3 GB/s is its
throughput ceiling — and the iGPU cannot beat it, because it drinks through the
same straw.

## Measurement 1 — model tier ceiling (CPU lane)

Method: ollama's own reported timings (`eval_count`/`eval_duration`,
`prompt_eval_count`/`prompt_eval_duration`), 200-token generations, warm runs
only — the same style `images/inference/engine-tuning.sh` already uses for its
CUDA A/B.

| Tier | Model | Prefill tok/s | Generation tok/s | Predicted from bandwidth |
|---|---|---:|---:|---:|
| T0 | `qwen2.5:0.5b` | 108.9 | 20.5 | 30-40 |
| T1 | `tinyllama:1.1b` | 86.3 | 16.6 | 18-25 |
| T2 | `phi3.5:3.8b` | **19.0** | **5.96** | 5-7 |

T2's generation landing at 5.96 tok/s against a 5-7 prediction derived purely
from memory bandwidth is strong confirmation that the bandwidth model governs
this host.

**The load-bearing finding is prefill, not generation.** `spec_answer` retrieves
`--k 6` chunks (`forge-plan.sh:746`) — roughly 3,000 tokens of context. At T2's
19.0 tok/s prefill that is **~158 seconds before the first token**. T2's
disqualifier is therefore not its 6 tok/s generation; it is that it cannot read
its own retrieved context in usable time.

## Measurement 2 — the Vulkan iGPU lane (orders 410 / 481 / 482)

`images/inference/engine-tuning.sh` keeps `gpu-vulkan` on the conservative
`f16` / no-flash-attention path with the explicit comment that the lane is
**unmeasured**, and that "claiming an unmeasured win is exactly the kind of
'GPU tier in name only' the order-392 boundary rules forbid." Until now the
only measured lane was CUDA on macuahuitl (RTX A5000, 2026-07-29).

**The lane is now measured.** Stock ollama 0.32.13 ships a `vulkan` backend
(`lib/ollama/vulkan/ggml-vulkan.dll`, 48.4 MB) and a documented
`OLLAMA_IGPU_ENABLE` flag. With it set, discovery falls through
cuda_v12 -> cuda_v13 -> rocm_v7_1 -> vulkan and reports:

```
inference compute id=0 library=Vulkan name=Vulkan0
  description="Intel(R) UHD Graphics" type=iGPU total="7.9 GiB" available="7.2 GiB"
```

Both T0 and T2 load at **100% offload** (`size_vram == size` in `/api/ps`).

| Tier | Prefill CPU -> Vulkan | Generation CPU -> Vulkan |
|---|---|---|
| T0 `qwen2.5:0.5b` | 108.9 -> 17.9 (**-84%**, suspect — see caveats) | 20.5 -> 18.4 (-10%) |
| T1 `tinyllama:1.1b` | 86.3 -> **113.2 (+31%)** | 16.6 -> 13.7 (-17%) |
| T2 `phi3.5:3.8b` | 19.0 -> **30.4 (+60%)** | 5.96 -> 4.74 (-20%) |

**The iGPU wins compute-bound prefill and loses bandwidth-bound generation, and
the prefill win grows with model size.** That is exactly what the shared-memory
model predicts: prefill has enough arithmetic per byte moved to use the 24 EUs,
decode does not.

### Consequence: for the RAG path the iGPU wins end-to-end

`spec_answer` is prefill-dominated (large retrieved context, short cited
answer). For ~3,000 prefill tokens + a ~150-token answer at T2:

- CPU: 3000/19.0 + 150/5.96 = **~183 s**
- Vulkan: 3000/30.4 + 150/4.74 = **~131 s** (**28% faster**)

So the correct tier policy for a shared-memory iGPU host is *not* "GPU or CPU"
— it is **GPU for prefill-dominated expert queries, CPU for generation-heavy
work**.

### The iGPU is not universally better — but the "crossover below 1B" is WITHDRAWN

**CORRECTED 2026-08-17 (cycle 5).** This section originally concluded a
model-size crossover: "below roughly 1B parameters the Vulkan dispatch overhead
dominates and the CPU wins." That was built on T0's Vulkan prefill of
17.87 tok/s — **the very figure this document flags below as a suspected
shader-compilation artifact**. It was an artifact, and the conclusion should not
have been drawn from it.

Measured warm, with prompt caching defeated and offload verified via `/api/ps`:

| `qwen2.5:0.5b` | prefill tok/s | generation tok/s |
|---|---:|---:|
| CPU | ~91 | ~28.9 |
| Vulkan iGPU | **~296 (3.2x faster)** | ~20 (~30% slower) |

**The iGPU wins prefill at 0.5B too.** The prefill half of the crossover claim
is wrong and is withdrawn.

What survives, restated precisely:

- **The iGPU wins compute-bound prefill and loses bandwidth-bound generation**,
  and that pattern holds at 0.5B, 1.1B and 3.8B alike — it is not size-gated in
  the range measured.
- ~~**The embedding loss is real and stands**: `nomic-embed-text` (137M) was 58%
  slower on Vulkan (4287 ms/chunk vs 2714).~~
  **WITHDRAWN 2026-08-17 (cycle 12).** That figure had two defects this loop
  only learned about later: it was taken with **no warm-up**, before cycle 9
  established that the first dispatch on a Vulkan/dzn path pays pipeline
  compilation and reads at roughly CPU speed; and it used a **synthetic
  ~2,000-char chunk against a real corpus p50 of 254 chars**, so it did not
  measure the workload it was used to reason about. Re-measured on real chunks
  with warm-up and interleaved repetitions: the iGPU is **~22% FASTER**
  (460.3 vs 586.6 ms/chunk, offload verified 100% vs 0%).
  This is the expected answer, not a surprise: an embedding is one forward pass
  with **no decode phase**, i.e. prefill-shaped work — the shape the iGPU wins.
  Note this section previously survived the cycle-5 correction *because* it was
  called out as the exception that stands; preserving it preserved the
  measurement error. See
  `plan/issues/research/embeddings-are-prefill-shaped-igpu-wins-2026-08-17.md`.
  The unified rule replacing both exceptions: **route by workload shape** —
  prefill-shaped work (prompt processing, embeddings) to the iGPU,
  decode-shaped work to the CPU on this class of part.
- **Any tier policy that routes all models to one engine is still wrong here** —
  but the axis is *workload shape* (prefill-heavy vs generation-heavy vs
  embedding), not parameter count.

Full detail: `plan/issues/research/engine-parity-ollama-vs-llamacpp-2026-08-17.md`.

### The detector gap is ~10 lines

`detect_inference_tier()` (`crates/tillandsias-headless/src/main.rs:3237-3265`)
has exactly four arms and **no Intel/Vulkan branch**, while
`engine_slots.rs:99-102` already pins `OLLAMA_VULKAN=1` for a `gpu-vulkan`
tier **no probe can ever emit**. The evidence to close that gap now exists.

Also note `engine-tuning.sh` reads VRAM via `nvidia-smi` only, so this host
resolves to `TUNING_VRAM_MB=0` -> tier `cpu`. And `models.json` gates T2+ on
`vram_required_gb`, a field that is meaningless on shared memory: ollama
reports 7.9 GiB "available" here, which would nominally admit T3, yet T3 is
bandwidth-disqualified. **The tier gate should key on measured throughput, not
on a VRAM field that does not apply.**

## Measurement 3 — the order-552 budget

> **SUPERSEDED 2026-08-17 (cycle 10).** Every input below was a proxy: the chunk
> count was an estimate (`816k tokens / 512`), the per-chunk cost was measured
> against a **synthetic** ~500-token chunk, and the endpoint was the bare-metal
> Windows ollama the operator has since removed. Re-measured with the real
> chunker on the sanctioned endpoint: the corpus is **9,909 chunks, not 1,592**
> (p50 236 chars, not 512 tokens) and costs **698 ms/chunk, not ~2,900**. Full
> rebuild is **115 min** (worse than stated below); a 10-chunk delta is **7.0 s**
> (4x better). Most importantly the conclusion's REASON was wrong: delta
> re-embed is **free on 96% of commits** (they never touch
> `openspec/specs`/`cheatsheets`/`methodology`) and costs **~15-45 s on the other
> 4%** — a bimodal cost, so async is needed for the TAIL, not for throughput.
> Full measurement:
> `plan/issues/research/order-552-real-reembed-cost-measured-2026-08-17.md`.

Operator's threshold: ~1-2 s is invisible to a user; tens of seconds is
unusable and wasteful.

Corpus measured on `origin/windows-next`:

| Corpus | Files | Bytes |
|---|---:|---:|
| `openspec/specs` | 171 | 1,110,732 |
| `cheatsheets` | 234 | 1,609,726 |
| `methodology` | 59 | 541,992 |
| **total** | **464** | **3,262,450 (~816k tokens, ~1,592 chunks at 512 tok)** |

`nomic-embed-text` on this host: **~2.9 s per ~500-token chunk**
(2881 / 2980 / 2871 ms across three runs, `dim=768`, clean state).

**Batching does not rescue it.** Ten chunks in one `/api/embed` call cost
2343 ms/chunk versus 2714 ms/chunk sequentially — a 14% saving. The cost is
irreducible compute, not per-call overhead.

| Scenario | Chunks | Cost |
|---|---:|---:|
| Full rebuild | 1,592 | **~62-77 min** — unusable |
| Delta, 40 chunks | 40 | ~2 min — unusable |
| Delta, 10 chunks | 10 | **~23-29 s** — still unusable |
| Budget target | — | 1-2 s |

**Conclusion for order 552: a SYNCHRONOUS commit-time re-embed cannot meet the
budget on the floor host at any realistic delta size.** It must be
asynchronous/backgrounded — precisely the shape
`scripts/hooks/post-commit-expert-refresh.sh` already uses for the cargo
rebuild (fork, `disown`, <50 ms synchronous). Order 547's decision to chunk for
delta re-embed remains correct; delta alone is simply not sufficient here.

## Finding — the real unmeasured per-commit cost is the cargo rebuild

The commit-hook "RAG retrain" the operator was worried about **does not exist
yet**: `post-commit-expert-refresh.sh:34-43` states L0 corpora have no index
("the engine reads files fresh at query time... No index to refresh") and the
L1 prose re-index is a commented-out placeholder.

The genuine per-commit cost is the backgrounded
`cargo build --release -p tillandsias-plan` in that same hook:
**600 s timeout, no debounce, and no single-flight lock.** On 4 E-cores, rapid
commits touching the plan crate stack concurrent release builds against the
same 4 cores. This is unmeasured on **every** host and is one `timing_emit`
away from being answered.

This became LIVE on this host mid-session, and the transition is worth
recording. At 15:0x the checkout had no hooks at all (`.git/hooks` held only
`*.sample`, `core.hooksPath` unset at local/global/system scope), so per-commit
cost was literally zero. At 15:23 `./build.sh --check` installed
`pre-commit`, `post-commit` and `pre-push`. From that point the backgrounded
`cargo build --release -p tillandsias-plan` fires for real on any commit
touching the plan crate — on 4 E-cores, with no debounce and no single-flight
lock.

**A `core.hooksPath` probe is therefore not a durable answer to "are hooks
installed?" on a host that has not yet run a build.** Any check that samples it
before first build gets a false negative.

Second finding from the same transition: the installed `pre-commit` hook runs
without the interactive session's PATH, so `scripts/check-cheatsheet-tiers.sh`
failed with `line 57: cargo: command not found` and degraded to a non-blocking
validation ERROR. The hook found cargo absent on a host where cargo is
installed and on PATH for every interactive shell. Hook PATH is its own defect
surface.

## Finding — in-distro ollama in the RUNTIME distro is not durable

`scripts/with-wsl2-builder.sh:26-31` states the build distro is deliberately
NOT the runtime `tillandsias` distro because **destructive smoke e2e
unregisters that distro on every run**. Ollama installed into the runtime
distro therefore does not survive an e2e cycle.

This bears directly on 718-nkm2, whose stated test is "pick by which one an
unattended cycle can re-establish after a reboot without an operator." Option A
(in-distro ollama) must specify **which** distro, and the runtime one fails
that test unless re-provisioning is automated.

Related WSL2 substrate facts measured here:

- `/dev/dxg` is present and `/usr/lib/wsl/lib` carries
  `libd3d12.so` / `libd3d12core.so` / `libdxcore.so`, but **`/dev/dri` does not
  exist** and no Intel Vulkan driver is installed in the distro. Vulkan inside
  WSL2 would require Mesa's experimental `dzn` (Vulkan-on-D3D12) shim.
  **Moving inference into WSL2 therefore forfeits the +31-60% prefill win
  measured above** unless `dzn` is provisioned and proven.
- Ollama's Linux asset is now `ollama-linux-amd64.tar.zst` (**zstd**, not the
  `.tgz` that older recipes fetch); `https://ollama.com/download/ollama-linux-amd64.tgz`
  returns **404**. Any script still using the `.tgz` URL is broken.

## Host-config hazards recorded at onboarding

- **No `%USERPROFILE%\.wslconfig`** — WSL2 takes ~50% of RAM (~8 GB, measured
  `MemTotal 8016488 kB`) and all 4 logical processors, uncapped.
  **CORRECTED 2026-08-17**: this entry originally added "and cgroup v2 is not
  enabled, so any podman `--memory`/`--cpus` flag is a silent no-op until that
  changes." **That is false**, and the claim came from an onboarding survey
  rather than from measurement. Measured directly in BOTH distros, before any
  `.wslconfig` existed: `stat -fc %T /sys/fs/cgroup` -> `cgroup2fs`, with
  `cgroup.controllers` = `cpuset cpu io memory hugetlb pids rdma`. The `memory`
  controller is present, so podman resource limits are already enforceable and
  the claimed ordering constraint on memory-budget work does not exist. See
  `plan/issues/optimization/wslconfig-mirrored-resolves-endpoint-ambiguity-2026-08-17.md`.
  Separately, `cheatsheets/runtime/wsl2-isolation-boundary.md:113` claims
  `tillandsias --init` writes `.wslconfig` — **no Rust does**; `wsl.rs:288-317`
  only reads it as a remediation hint. That is a live cheatsheet defect.
- **`core.autocrlf=true`, `core.fileMode=false`** — reproduces both known
  Windows fixture defects; resulting fixture reds are known host config, not
  regressions.
- **Windows Defender real-time protection is ON** and exclusions cannot be read
  or set without elevation. Windows itself prompts during cargo builds that
  IO-intensive work belongs in WSL2. `with-wsl2-builder.sh:37-41` already
  defaults `CARGO_TARGET_DIR` to a distro-native path for exactly this reason;
  `target/` reached 74 GB on the reference host and must never land on the
  NTFS volume.
- **Disk**: the operator reclaimed a Linux partition during onboarding,
  taking C: from 179 GB / 74 GB free to **237.4 GB / 132.6 GB free**, whole
  disk allocated. Disk is no longer the binding constraint.
- **Workflow/agent concurrency here is 2** (`min(16, cores-2)`), so any
  fan-out tooling serializes into waves on this host.

## Caveats — what is NOT yet publication-grade

1. **The CPU lane was measured under contention** (a 7 GB Build Tools installer
   and two agents were running). CPU numbers are therefore *understated*; the
   true CPU/GPU gap is likely narrower than the table shows.
2. **T0's Vulkan prefill (17.9 tok/s) is suspect** — first model loaded into a
   fresh server, so it plausibly includes Vulkan shader/pipeline compilation.
   It is reported, not relied upon.
3. A first embedding measurement of 8977 ms/chunk was **discarded**: the test
   chunk was random base64, which tokenizes near-worst-case. Replaced with real
   corpus text.
4. Ollama GPU bootstrap discovery costs **2.23 s at server start** (probing
   cuda/rocm before vulkan) — relevant to the startup-speed mandate, not yet
   attacked.

A clean, quiesced re-run of both lanes is owed before these numbers are used to
set policy.

## Reproduction

`scripts/bench-inference-floor.sh` (added alongside this file) emits the
falsifiable grammar:

```
gen: model=<n> tier=<T> engine=<e> load_ms=<N> prefill_tok_s=<F> gen_tok_s=<F> \
     prompt_tok=<N> eval_tok=<N> total_ms=<N>
embed: model=<n> engine=<e> n=<N> total_ms=<N> per_chunk_ms=<F> chunks_per_s=<F>
```

CPU lane: unset `OLLAMA_IGPU_ENABLE`. Vulkan lane: `OLLAMA_IGPU_ENABLE=1`, and
confirm `size_vram == size` in `/api/ps` before trusting the label.

## Open governance question (NOT self-enabled)

`methodology/convergence.yaml:410-461` makes "slow steps, stale caches, timing
regressions" a named **bar-raise class the loop MAY propose but MUST NOT
enable**. The operator's mandate for this host is effectively that bar-raise.
It is **proposed here, not adopted** — approval (who / when / scope) is owed
before slowness is filed as a findings class.

Relatedly, "this host is the fleet's lower bound" is **not expressible in any
schema today**: `pickup_role` is a closed `linux|macos|windows|any` enum
(`scripts/select-work-batch.sh:134`), `capability_tags` has no hardware
vocabulary, and `scripts/inference-tier-probe.sh` emits `tier:cpu` for an N100
and a 64-core Threadripper alike. Routing perf work to the floor host currently
depends on operator instruction, not on the selector.
