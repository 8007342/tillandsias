# PoC: beginner experts answering on the XDNA2 NPU (2026-07-31)

- class: exploration/ (proof-of-concept advancing orders 544 + 543; operator-directed)
- host: yoga (linux_immutable), AMD Ryzen AI 5 340 / XDNA2, kernel 7.1.4
- cycle: meta-orchestration full mode, v0.5 drain
- deliverable of: order 546 (npu-beginner-experts-serving, filed this cycle)
- builds on: plan/issues/npu-container-citizenship-e2e-2026-07-29.md (orders 541-544),
  plan/issues/experts-construction-decision-2026-07-17.md (order 393)

## Headline

**Beginner experts run on the NPU today, grounded in real project corpora.**
Lemonade Server 11.5.0 + FastFlowLM (qwen3-0.6b-FLM) served two experts on the
XDNA2 NPU via **request-time corpus stuffing** (the order-544 engine-neutral
mechanism — no ollama Modelfile, no `ollama create`): a **methodology expert**
(corpus = methodology.yaml) and a **plan expert** (corpus = a plan/index.yaml
slice). Both answered from the stuffed corpus with hard NPU-engagement evidence.
The proof is self-contained, ran unprivileged (memlock shim), and left the NPU
suspended and the port free.

## What ran (reproducible: scratchpad/npu-experts/run-proof.sh)

lemond started with the `nolock.so` LD_PRELOAD shim on :13305, model
qwen3-0.6b-FLM, two `/api/v1/chat/completions` calls with
`{role:"system", content:"<corpus>"}` + `{role:"user", content:"<question> /no_think"}`.

### Expert 1 — methodology (corpus = methodology.yaml, 16 KB / 3647 prompt tokens)
- Q: *"Before pushing a non-linux-next branch, what must I do first, and which
  branch do Linux checkpoints go to?"*
- A: *"Before pushing a non-linux-next branch, you must first ensure that your
  local environment is clean. Linux checkpoints will go to the `linux-next`
  branch."*
- Verdict: **branch fact CORRECT; pre-push rule SOFTENED.** Ground truth
  (methodology `pull_merge_cadence.pre_push_gate`): *merge `origin/linux-next`
  into the branch and resolve conflicts before every push of a non-linux-next
  branch.* The 0.6B model retrieved the explicit branch fact but generalized the
  buried merge rule out of a 16 KB corpus.
- NPU: runtime_status **active**, xdna IRQ delta **+3794**; prefill **1964 t/s**
  (TTFT 1.86 s for 3647 tokens), decode 51 t/s.

### Expert 2 — plan (corpus = NPU packets slice, 12 KB / 3335 prompt tokens)
- Q: *"Which packet blocks npu-inference-container (order 543) from starting, and
  what is that blocker's status?"*
- A: *"The packet block npu-inference-container (order 543) is the
  'optional-component-registry' packet, which is currently **ready**."*
- Verdict: **FULLY CORRECT + cited.** optional-component-registry (542) is the
  `blocks:` edge on 543; status ready.
- NPU: runtime_status **active**, xdna IRQ delta **+364**; prefill **1945 t/s**
  (TTFT 1.71 s), decode 53 t/s.

Cleanup verified: runtime_status → suspended, lemond stopped, :13305 free.

## The architectural lesson (validates order 393 + 544)

The plan expert nailed a cited answer because its corpus was **small and the
fact explicit**; the methodology expert softened because it had to *find* a
buried rule in 16 KB. This is the exact case for the order-393 split, now with
first-party evidence:

> **Deterministic retrieval narrows the corpus; the NPU LLM only synthesizes
> prose from the retrieved, cited facts.** The compiled `tillandsias-plan`
> binary (crates/tillandsias-plan, 100% accurate YAML queries + citations) must
> do the retrieval; the NPU model turns those exact facts into a readable
> answer. Never ask the tiny model to *retrieve* from a large corpus — it
> generalizes. Ask it to *rephrase* facts it was handed — it is reliable.

Quantitative backing: NPU prefill is ~1950 t/s, so even a 3–4 K-token stuffed
context costs <2 s TTFT and KV occupancy stayed ~15 % (256 K context barely
touched) — there is ample room to stuff *retrieved* facts, but stuffing whole
files trades accuracy for no benefit.

## Why this belongs on the NPU (concurrent co-processor, per 2026-07-31 directive)

Expert synthesis is a **background/low-priority** workload: it should never
compete with the developer's interactive GPU/CPU inference. On a fat GPU+NPU
desktop the NPU runs the always-warm expert-synthesis lane in parallel with the
big GPU (research headline 7 of the citizenship doc); on an NPU laptop it is the
primary low-power lane. Either way, expert traffic is exactly the
sustained/background class order 484's router should pin to the NPU — and doing
so dissolves the GPU-VRAM pressure that sibling orders 522/527 flag for
keep-alive'd expert models.

## Path to "available to the forge at launch"

The current beginner experts (forge-plan.sh `plan_answer`/`methodology_ask`
wrapping the compiled binary; project-info.sh deterministic queries) are
retrieval-only. The NPU adds an OPTIONAL **synthesis** layer on top:

1. The npu-inference container (order 543) exposes `qwen3-0.6b-FLM` at the
   enclave `/v1` endpoint when the host has a usable NPU.
2. A synthesis tool (extension of forge-plan.sh) calls the compiled binary for
   cited facts, POSTs `{system: cited-facts, user: question}` to the enclave NPU
   `/v1`, and returns the prose answer WITH the deterministic citations attached.
3. When no NPU is present, the tool degrades to returning the deterministic
   cited facts verbatim (no synthesis) — the experts still work, just terser.
4. Registration: the NPU synthesis endpoint joins the experts launch-state
   (FORGE_EXPERTS_STATE_DIR) so `experts: ready` reflects it, and endpoint
   discovery uses the probe-driven TILLANDSIAS_NPU_HOST from order 543.

The exact file:line seam is captured in order 546's outcome (informed by the
wiring-map produced this cycle).

## Residual / notes

- Corpus-narrowing (retrieval before stuffing) is the accuracy lever, not model
  size — it is the concrete first tuning step for order 546.
- The proof used the nolock shim (8 MiB memlock cap unremediated on this host);
  production still owes the installer memlock step (order 543).
- Artifacts (local, scratchpad): run-proof.sh, corpus-*, answer-*.json, proof.log.
