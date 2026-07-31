# Design + PoC: the GPU fat RAG spec expert (tiered local-expert system) — 2026-07-31

- class: exploration/ + research/ (operator-directed; extends the local-expert layer)
- host: yoga (linux_immutable), AMD Ryzen AI 5 340 — XDNA2 NPU + Radeon 840M iGPU
- cycle: meta-orchestration continuation (v0.5 experts milestone)
- deliverable of: orders 547-552 (filed this cycle)
- builds on: npu-experts-poc-2026-07-31.md (NPU beginner experts, order 546),
  npu-container-citizenship-e2e-2026-07-29.md (orders 541-544),
  experts-construction-decision-2026-07-17.md (order 393)

## Headline

**The fat RAG spec expert runs on this mid-tier iGPU today, and the tiered
design needs almost no new machinery — the existing citation Envelope's
`confidence` field IS the tier router.** NPU serves small always-warm beginner
experts (order 546); the GPU hosts a NEW fat expert doing RAG over the
~950K-token whole-spec corpus (340 specs + 266 cheatsheets + 56 methodology
files — too big for any context); cloud is the terminal fallback. Every tier
synthesizes ONLY over locally-retrieved cited spans, so answers always carry
resolvable citations and `verify()` still passes. Proven on-host: fat synthesis
on the iGPU/Vulkan (GPU 100% busy) + embedding retrieval (nomic on GPU, no-python
cosine).

## PoC — what ran on this host (scratchpad/npu-experts/run-*-proof.sh)

### Fat spec expert — Qwen3-4B (Q4_0, 2.4 GB) over a retrieved multi-spec context
Retrieved context = 8 isolation/egress spec files, ~5.5K tokens (a cross-cutting
query the NPU beginner tier cannot hold). Question: *"How does Tillandsias keep
the forge isolated from the host and control the forge's outbound network
access? … cite the spec FILE headers."*

Answer (verbatim, on-GPU run): *"…creates and manages an internal podman network
named `tillandsias-enclave` that isolates forge, git, inference, and proxy
containers… The forge container is attached only to the `tillandsias-enclave`
network… The proxy container is the only one with external access, as it is
attached to both the `tillandsias-enclave` network and the default bridge…
Cited spec FILE headers: `enclave-network` (spec.md)."* — **accurate,
cross-cutting, cited.**

| run | device | prefill t/s | decode t/s | wall | GPU busy |
|---|---|---:|---:|---:|---:|
| CPU (lemonade default `llamacpp:cpu`) | CPU | — | ~3.6 | 59 s | **0 %** |
| Vulkan `llama-server -ngl 99` | **iGPU** | **181.8** | **15.5** | 40 s | **100 %** |

- **Definitive GPU proof**: `gpu_busy_percent` hit **100 %** during the Vulkan
  run vs **0 %** on the CPU run; Vulkan enumerated `AMD Radeon 840M (RADV
  KRACKAN1)`. The iGPU is ~**4× the CPU decode** for this 4B model.
- **Prefill-dominated on mid-tier**: 30 s of the 40 s wall was prefilling the
  5.5K retrieved context (182 t/s). → keep the retrieved context TIGHT on
  mid-tier (fewer/smaller chunks); the fat expert is a background/quality lane
  here, not an interactive one.
- **Lemonade defaulted to CPU** for llamacpp; forcing the iGPU required the
  Vulkan `llama-server` variant with `-ngl 99` (both `bin/llamacpp/{vulkan,cpu}/`
  ship). The GPU slot must pin the Vulkan backend explicitly (packet 549).

### Embedding retrieval primitive — nomic-embed-text-v1 (GGUF) on the same server
- Query *"how is the forge stopped from reaching the internet directly"*:
  `cos(query, egress-allowlist chunk) = 0.7309` **>** `cos(query, tray-icon
  chunk) = 0.4974` → **correct chunk ranked first.** 768-dim, cosine computed in
  **awk (no python)**. Proves the RAG retrieval primitive works locally on the
  GPU server.

Clean teardown verified: llama-server + lemond stopped, GPU idle, RAM freed.

## The architecture (design workflow, cited)

**The tier router already exists — it is the `confidence` funnel, not a new
classifier.** The compiled `tillandsias-plan` engine answers a CLOSED intent set
(answer.rs classify; methodology.rs route) and REFUSES everything else as
`confidence=unsupported` (answer.rs:211-230 makes an uncited confident answer
unrepresentable). That refusal IS the boundary:

1. Always run the deterministic engine first (free, network-free).
2. `confidence != unsupported` → **beginner** → NPU synthesis (order 546).
3. `confidence == unsupported` AND spec-shaped (a JOIN across the 340-file
   corpus) → **fat** → GPU RAG.
4. GPU absent OR cosine below floor OR hardest → **cloud** — which still
   synthesizes only over locally-retrieved cited spans.

**The no-python split is at the network boundary**: retrieval math + chunking +
citation/verify live in the network-free Rust crate; embedding + synthesis are
POSIX shell over the `/v1` endpoints (the order-546 `synthesize_prose` shape,
generalized). This preserves the falsifiability contract — `synthesize_prose`
copies `citations`/`freshness`/`confidence` verbatim and replaces only the prose,
so the synthesizer **cannot fabricate a citation** and `verify()` survives local
synthesis.

**RAG stack (no-python):** span-addressable chunks (reuse `methodology.rs
index_text` for yaml; a NEW heading-section chunker for md; each chunk carries
path + line_start + line_end + heading decl + content_hash) → a FLAT f32 blob +
JSONL sidecar (~2-4K chunks → brute-force cosine top-k is sub-ms; NO ANN
dependency until the corpus grows ~10×) → retrieved methodology/plan chunks are
re-run through the deterministic engine to upgrade their citations to `exact`
(the deterministic layer is its own re-ranker) → GPU synthesis → build+`verify`
the Envelope. Delta re-embed on commit (order 396) keyed on content_hash; index
is tmpfs/ephemeral like `ensure_forge_experts`.

## Hardware tiers

- **Mid (this iGPU laptop)**: 3-4B Q4 is the comfortable fat expert (~2.5-3 GB
  resident) via Vulkan; 7B Q4 is possible but tight — it shares the ONE 11.5 GiB
  pool with the ~0.7 GB NPU model, the dev's own inference/editor/browser, and
  the OS (zram thrash is the failure mode). Accuracy loss vs top tier is small
  because retrieval already narrowed the corpus to a few-K cited tokens — the mid
  tier loses fluency, not groundedness. Keep the NPU beginner model warm; load
  the Vulkan fat expert on demand; evict when idle.
- **Top (fat discrete GPU + small NPU builder)**: 14B Q4/Q5 (~8-11 GB VRAM) is
  the sweet spot; 32B Q4 fits a 24 GB card. Because VRAM is a SEPARATE pool from
  system RAM, the NPU streams beginner experts (~52 t/s) **concurrently** with
  the GPU fat expert (14B ~30-60 t/s) — genuine heterogeneous parallelism, no
  VRAM contention. The NPU absorbing always-warm expert residency dissolves the
  GPU-VRAM keep-alive pressure orders 522/527 flag.
- **Low (no GPU)**: CPU RAG (slow but works) or cloud fallback; beginner experts
  still run on NPU/CPU. Fail-soft floor answers with cited facts at ZERO LLM
  tokens when no accelerator exists.

## Why this is the win-win the operator called (velocity / self-verify / cloud-token cut)

- **Velocity / near-free inference**: the ~950K-token corpus fits no context, so
  local RAG is what makes the whole spec answerable at all; NPU prefill ~1950 t/s
  (<2 s TTFT at ~5-15 W) and a grounded GPU RAG query in ~1-3 s on top-tier
  (~3-8 s mid-tier) — vs cloud round-trips + rate limits.
- **Runtime self-verification without cloud**: `verify()` re-derives that every
  cited span contains the claimed token; synthesis cannot fabricate citations →
  falsifiable answers produced entirely locally.
- **Cloud-token reduction**: every expert query is fully offloaded (~2-4K
  retrieved-context + 200-500 completion tokens that never leave the host); a
  session of dozens-to-hundreds of spec/plan lookups avoids hundreds-of-K to
  millions of cloud tokens.
- **Stable RAG between commits**: experts are commit-stable (refresh on commit,
  order 396) and semantically isolated → the index is stable, no constant
  re-embed churn — reliable RAG the operator can trust and dogfood.

## Packets filed this cycle (547-552)

- **547 fat-spec-corpus-index** — Rust chunker + flat-vector store (span-
  addressable, content-hash, `spec-index`/`spec-retrieve` subcommands, network-
  free). EXIT: retrieved citations pass `verify()`; delta re-embed touches only
  changed chunks; a fabricated chunk citation is refused.
- **548 spec-expert-embed-and-synthesis** — `spec_answer` tool in forge-plan.sh
  (embed via pinned slot, retrieve, synthesize on GPU slot, build+verify
  Envelope, fail-soft). EXIT: no-GPU → retrieval-only cited chunks; stub `/v1` →
  citations byte-identical, only prose differs; verify passes.
- **549 fat-spec-expert-gpu-slot** — optional capability-gated GPU embed+synth
  component (order 542 registry; SkippedNotApplicable when absent; Vulkan backend
  pinned per the PoC; endpoints in container_profile.rs; enclave alias in
  NO_PROXY). EXIT: present on GPU host, absent with zero footprint otherwise.
- **550 tiered-expert-router** — the confidence-escalation funnel as an order-484
  router-consumer (pure over serialized fixtures; this host is a committed
  fixture). EXIT: single-node lookup never invokes RAG; unsupported spec-wide
  query escalates to GPU then cloud; every hop preserves the citation contract.
- **551 spec-expert-groundtruth** — a `spec.answer` engine + cross-cutting query
  set in groundtruth.rs (grader unchanged). EXIT: green at HEAD; a wrong expected
  span turns a case red.
- **552 spec-index-commit-freshness** — wire delta re-embed into order-396
  on-commit refresh; ephemeral tmpfs lifecycle. EXIT: one-file commit re-embeds
  only that file; content-hash mismatch flags a stale index.

## Residual / notes

- Mid-tier fat-expert latency is prefill-bound → retrieval must be tight (small
  k, small chunks) on shared-RAM hosts; the model choice (3-4B) is the honest
  ceiling here, 14B+ is the top-tier story.
- Lemonade's llamacpp defaults to CPU; the GPU slot MUST pin the Vulkan variant
  (`-ngl 99`) — captured in packet 549.
- Artifacts (local scratchpad): run-gpu-proof.sh, run-vulkan-proof.sh,
  rag-context.txt, answer-vulkan-spec.json, gpu-proof.log, vulkan-proof.log.
  Models kept: Qwen3-4B-GGUF, nomic-embed-text-v1-GGUF (HF cache).
