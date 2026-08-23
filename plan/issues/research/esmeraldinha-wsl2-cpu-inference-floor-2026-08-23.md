# The Windows low-end floor, measured in WSL2: decode is at bare-metal parity, the embedder is 14.6x off the reference host, and the benchmark harness has been publishing a cached prefill

- classification: research
- filed: 2026-08-23 (windows/ESMERALDINHA, meta-orchestration cycle), at
  `windows-next` `fb80c579a` (= `origin/linux-next`)
- packet: **858-tnnv** — the Windows sibling of 855-wrr3, filed rather than
  claimed, per the coordinator's instruction that the Silverblue row stay with
  the Silverblue host
- related: 855-wrr3 (the Silverblue cousin), 853-6gz3 (expert validation
  layer — this supplies its floor), 850-bif2 (capability rows), 851-cduu
  (the stale-instrument packet this cycle also confirmed),
  `plan/issues/esmeraldinha-lower-bound-inference-floor-2026-08-16.md`
  (this host's bare-metal baseline),
  `plan/issues/research/intel-igpu-dzn-in-wsl2-measured-2026-08-17.md`
  (the dzn lane, which changes the iGPU adjudication — see below)

## Substrate, stated first because it is the difference from 855-wrr3

855-wrr3 measures a **Silverblue bare-metal** host with podman. This is its
Windows cousin and the substrate is **not** the same shape: inference runs
inside a **WSL2 guest** (`tillandsias` runtime distro, Fedora 44, kernel
6.18.33.2-microsoft-standard-WSL2), on host-native ollama **0.32.14** — the
same ollama version the pinned `tillandsias-inference` image carries, which is
what makes the two rows comparable at all.

| | esmeraldinha (this row) | notes |
|---|---|---|
| CPU | Intel N100, 4 Alder Lake-N E-cores, no SMT | `physical: 4, logical: 4` |
| CPU flags | fma, avx, avx2, avx_vnni | no AVX-512 |
| Memory | 1x16 GB DDR4-2667, single channel | ~21.3 GB/s ceiling |
| RAM visible to the guest | 7.76 GB | machine has 15.78 GB |
| GPU | Intel UHD 24EU (8086:46d1) | adjudicated below |
| Engine | ollama 0.32.14, host-native in-guest | `OLLAMA_NUM_PARALLEL=1` |
| Engine label | verified by `/api/ps`, not claimed | `engine=cpu offload_pct=0` |

All numbers below were taken with **no other load on the box** (both cargo
builds had completed; the shared WSL2 VM was idle). That matters: this host's
2026-08-16 baseline was explicitly taken under contention and is understated.

## Decode / generation — trustworthy, and cross-validated

`qwen2.5:0.5b` (Q4_K_M), `num_predict=200`, ollama's own
`eval_count / eval_duration`:

| measurement | gen tok/s |
|---|---:|
| `bench-inference-floor.sh`, 200 tokens | **29.64** |
| sub-query shape, 32 tokens, run 1 | 27.25 |
| sub-query shape, 32 tokens, run 3 | 29.51 |
| this host's controlled in-guest CPU run, 2026-08-17 (dzn study) | 28.67 |

Four measurements across two harnesses and six days agree inside ~3%. Decode on
this host is **~28.5-29.6 tok/s** and the figure is solid.

`phi3.5:3.8b`: **6.53 tok/s** (200 tokens, total 30,856 ms, load 111 ms).
The 2026-08-16 bare-metal Windows CPU figure was 5.96 tok/s.

**So the WSL2 substrate costs nothing on the CPU decode lane** — both models
land at or slightly above their bare-metal Windows numbers. That is the useful
negative result: for CPU-only work, moving inference into WSL2 is free, and the
718-nkm2 substrate decision does not have to trade throughput for it.

## Embedder — the number the expert layer actually lives on

`nomic-embed-text` (137M), real prose (`methodology/philosophy.yaml`),
sequential one-round-trip-per-chunk unless stated:

| shape | per-embed ms | embeds/s |
|---|---:|---:|
| 250-char chunk (real corpus p50 is ~236-254 chars) | **437.3** | 2.29 |
| 2000-char chunk (what the bench harness sends) | 2451.5 | 0.41 |
| batch of 64 x 250-char | **408.3** | 2.45 |

Two independent runs of the 2000-char shape gave 2461.4 and 2451.5 ms — 0.4%
apart, so the harness is repeatable even where it is measuring the wrong chunk
size.

**Batching buys 6.6%.** That reproduces the 2026-08-16 finding (14% at n=10) in
the same direction and confirms its conclusion: on this host the embedding cost
is irreducible compute, not per-call overhead. A scheduler cannot batch its way
out of it.

### The ratio 855-wrr3 asked for

macuahuitl: **28 ms/embed** in batches of 64. esmeraldinha, same batch shape:
**408.3 ms/embed**.

> The floor is **14.6x slower** than the reference host at the embedder.

Stated as a ratio and not an adjective, as the packet required. Caveat kept
honest: the chunk length behind macuahuitl's 28 ms is not recorded in the
ledger line this was taken from; mine is 250 chars, chosen to match the
measured corpus p50.

### Corpus projection, using the corrected corpus constants

The 2026-08-17 correction established the real corpus is **9,909 chunks at p50
236 chars**, not the 1,592-at-512-tokens estimate:

| scenario | this host |
|---|---:|
| full re-embed, sequential | 4,333 s = **72 min** |
| full re-embed, batch-64 | 4,046 s = **67 min** |
| delta of 10 chunks | **4.4 s** |
| delta of 40 chunks | **17.5 s** |

Against the 115 min the 2026-08-17 bare-metal run projected — but that run was
contended, so read this as "WSL2 is not worse", not as a 1.6x win.

Order 552's conclusion is unchanged and now has a WSL2 number behind it: a
synchronous commit-time re-embed cannot meet the 1-2 s budget here at any
realistic delta size. 4.4 s for a 10-chunk delta is the best case.

## The expert-layer budget — 853-6gz3's floor (855 exit criterion 4)

An unfold-and-verify sub-query, measured in its real shape (~67-token prompt,
`num_predict=32`, prompts made unique early so the KV cache cannot serve them):

- 32-token answer: **1,885 ms** and **1,816 ms** wall
- 3-token answer: 926 ms and 911 ms wall
- add one 250-char query embedding: **+437 ms**

So **~2.3 s per unfold-and-verify sub-query**, end to end.

| tolerable answer time | sub-queries that fit |
|---|---:|
| 10 s | ~4 |
| 30 s | ~13 |
| 60 s | ~26 |

**And they are strictly serial.** `OLLAMA_NUM_PARALLEL=1`, four cores, one
memory channel: fanning out sub-queries here does not overlap them, it
time-slices the same silicon and the same ~21.3 GB/s. This is the load-bearing
constraint for 853-6gz3, and it is qualitative, not merely slower: a design
tuned on macuahuitl, where fan-out is close to free, does not degrade
gracefully here — it degrades **linearly in the fan-out width**. If the layer's
shape is "unfold into N sub-queries, verify each", then N is the latency
multiplier on this host and the floor is N x 2.3 s.

That is the number 853-6gz3 must design against.

## The iGPU, adjudicated honestly — and the row is incomplete

Both published rows say `present-unusable` with reason
`wsl2-no-dri-render-node`. As a row that is correct, and as a statement about
the hardware it is wrong, so it should not be left to stand unqualified.

What is confirmed this cycle, structurally:

- `/dev/dri` absent, `/dev/accel*` absent, `dxgkrnl` built into the kernel,
  `/dev/dxg` present, `libd3d12.so` / `libd3d12core.so` / `libdxcore.so` in
  `/usr/lib/wsl/lib`.
- The guest PCI bus carries only paravirtual functions — two virtio (0x1af4)
  and one Microsoft 0x1414:0x008e of class 0x030200. No 0x8086 function
  crosses.
- ollama's own discovery, with `OLLAMA_VULKAN:true` already set in its
  environment, found `inference compute id=cpu library=cpu` and nothing else.
  No GPU lane, out of the box.

So no DRI-expecting engine can attach, and in the distro's current provisioning
state the iGPU is genuinely unavailable. `present-unusable` is the right row
today.

But this host measured, on 2026-08-17, that the same Intel UHD **is** reachable
from inside WSL2 through `/dev/dxg` via Mesa `dzn` (Vulkan-on-D3D12) — ollama
bound it at **100% offload** (`size_vram == size`) and delivered **190.6 tok/s
prefill, 2.16x the CPU lane**, at a decode cost of 1.88x. Three Fedora packages
enable it, and yolanda measured the same path on AMD the day before, so the
lane is vendor-general.

> `wsl2-no-dri-render-node` is a **provisioning** statement wearing the costume
> of a **hardware** statement. The probe derives it from the absence of
> `/dev/dri` alone, and never asks what the device that *is* present affords —
> which is the exact inference error this host already made and corrected in
> cycle 7 ("absence of the expected interface is not absence of the
> capability").

Per the 806-2r4s vocabulary this is "ship a lane", not "buy hardware" — and
yolanda's universality write-up said as much, carefully, as "could in
principle". It is stronger than in principle: the lane has been **measured on
both vendors the fleet owns**. A scheduler reading `present-unusable` will not
ship it, so the vocabulary is doing the wrong work here. Filed as part of
858-tnnv rather than silently accepted.

## Two defects in the shared benchmark harness

Both affect every host that has run `scripts/bench-inference-floor.sh`, so they
are recorded here rather than fixed quietly.

### D1 — `prefill_tok_s` is measured against a filled prompt cache

`bench_model()` runs a warm-up with the identical prompt, then measures with the
same prompt. The warm-up's *output* is discarded, as its comment says; the KV
cache it fills is not, so `prompt_eval_duration` on the measured run covers a
cache hit.

Measured on this host, `qwen2.5:0.5b`, same prompt, same server:

| arm | prompt_tok | prompt_eval_ms | prefill tok/s |
|---|---:|---:|---:|
| identical prompt repeated (what the harness does) | 82 | 87 / 81 | **934.4 / 1008.4** |
| prompt with a unique suffix | 93-94 | 196-256 | 365.8 / 474.3 / 394.1 |
| this host under full 793-zumy controls, 2026-08-17 | — | — | **88.3** |

The harness reported **1334.59 tok/s** for this model this cycle. The
controlled figure for the same model, lane and machine is 88.3. Note the middle
arm is *also* wrong, and instructively so: appending a unique **suffix** leaves
the long common **prefix** cacheable, so it measures only the novel tail. The
control that works is a prompt that is unique **early**, which is what
793-zumy's method already specified.

Consequence: every `prefill_tok_s` this harness has emitted, on any host, is
inflated by an unknown factor, and none of them are comparable to the
793-zumy-method numbers in the ledger. Decode is unaffected — it agrees with
the controlled run to 3% — and so is `embed:`. No prefill rate is published in
this document for that reason.

Fix direction: generate a unique prompt per repetition (unique token *first*),
isolate prefill with `num_predict=1`, and discard the first post-load
repetition — the cold-dispatch trap 793-zumy documented pulls the other way and
both controls are needed.

### D2 — the `project:` line multiplies two superseded constants

`CORPUS_CHUNKS` defaults to **1592**, the estimate the 2026-08-17 measurement
replaced with **9,909**, and it is multiplied by the per-chunk cost of a
**2000-char** chunk when the real p50 is ~236. This cycle it emitted
`full_rebuild_s=3918.5` (65 min) against a true ~72 min.

It is close, and it is close **by cancellation** — the chunk count is 6.2x too
low and the per-chunk cost is 5.6x too high. A number that is right by
cancellation stops being right the moment either input is corrected alone,
which is precisely what happens when someone fixes one of the two. Both
constants should come from the real chunker.

## Residuals — what this row does NOT close

Named explicitly rather than left to look complete:

1. **No alternative runtime was evaluated** (855 exit criterion 5). llama.cpp
   is not installed in the runtime distro and installing it is a host mutation
   outside this cycle's scope. The comparable prior work is
   `plan/issues/research/engine-parity-ollama-vs-llamacpp-2026-08-17.md`.
2. **No true cold-bootstrap number** (855 exit criterion 6). This cycle ran on
   a checkout cloned 40 minutes earlier, but the WSL cargo dependency cache
   from 2026-08-17 survived the re-clone — which is the 851-cduu hazard, not a
   cold start. Warm-cache figures for the record: `tillandsias-plan` release
   rebuild 1m21s, router sidecar 2m01s, `tillandsias-headless` release 3m27s.
   A genuine cold number needs the distro's cargo cache cleared and is
   measurable exactly once.
3. **Prefill throughput is unmeasured on this substrate this cycle**, per D1.
   The 2026-08-17 controlled figure (88.3 tok/s CPU, 190.6 dzn) stands as the
   best available, and was taken in `tillandsias-build`, not the runtime distro.

---

## Prefill, now measured — the residual this document opened with is closed

Filed above as residual 3: "Prefill throughput is unmeasured on this substrate
this cycle, per D1." D1 is fixed (858-ihcb, same day, next cycle) and the
numbers exist. `scripts/bench-inference-floor.sh` now isolates prefill with a
unique-token-first prompt per repetition, `num_predict=1`, the cold dispatch
discarded, and reports the median of three with its range.

| `cpu-wsl2`, esmeraldinha | prefill tok/s | range | decode tok/s |
|---|---:|---|---:|
| `qwen2.5:0.5b` (T0) | **138.68** | 122.25-144.32 | 28.99 |
| `phi3.5:3.8b` (T2) | **17.67** | 17.63-17.99 | 6.38 |

What the harness reported for the same models before the fix: **1334.59** and
**480.93**. A 9.6x and a 27x overstatement.

**The cross-check that makes these trustworthy.** This host measured the same
two models on **bare-metal Windows** on 2026-08-16, with a different harness on
a different substrate: prefill 108.9 (T0) and 19.0 (T2). The corrected WSL2
figures land within ~10% of those. The cached figures were 12x and 25x away
from them. An independently-taken measurement the new code knew nothing about
now agrees with it, and did not agree with what the harness said yesterday.

Two consequences worth carrying forward:

1. **T2's prefill disqualifier stands, and is now confirmed on WSL2.** The
   2026-08-16 record's load-bearing finding was that `phi3.5:3.8b` cannot read
   its own retrieved context in usable time: at 19.0 tok/s prefill, a `--k 6`
   retrieval of ~3,000 tokens is ~158 s before the first token. At the WSL2
   figure of 17.67 it is ~170 s. Nothing about moving into WSL2 rescues T2.
2. **The decode/prefill split on this host is ~4.8x for T0 and ~2.8x for T2**
   (prefill tok/s over decode tok/s). Both are prefill-favoured, which is the
   shape that made the dzn iGPU lane worth measuring in the first place — and
   the lane is still unprovisioned in the runtime distro, so the CPU numbers
   above are what a scheduler gets today.

The embed figures are unchanged by the fix (the defect was confined to
`prompt_eval_duration`): **433.1 ms/chunk at 250 chars**, against 437.3
yesterday — 1% apart across two days and two harness versions. The corpus
projection, now fed the measured 9,909-chunk count rather than the superseded
1,592 constant, gives **4,291.6 s = 71.5 min**, matching the 72 min projected
by hand above.
