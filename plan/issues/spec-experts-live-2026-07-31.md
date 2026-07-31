# Live proof: the spec RAG expert answers end-to-end (orders 547 + 548) — 2026-07-31

- class: exploration/ (implementation evidence for orders 547 done + 548)
- host: yoga (linux_immutable), XDNA2 NPU + Radeon 840M iGPU
- deliverable evidence for: order 547 (spec-index/spec-retrieve, DONE) and the
  548 serving logic (proven as a script; MCP integration is the remaining 548 work)

## What was proven

The full fat-spec-expert pipeline runs end-to-end on-host and produces a
**verified, cited** answer, with the network split exactly where the design put
it (Rust does chunk/retrieve/envelope; shell does embed/synthesize over /v1):

1. **spec-index** (Rust, network-free) chunked the LIVE corpus → **10,113
   chunks** (4131 spec + 5392 cheatsheet + 590 methodology), each span-
   addressable with `path/line_start/line_end/kind/key/content_hash`.
2. **embed** (shell → lemonade `nomic-embed-text-v1`, 768-dim) over a bounded
   370-chunk sample (170 isolation/egress targets + 200 real distractors; full-
   corpus embed is the launch-time job, order 552).
3. **spec-retrieve** (Rust, cosine top-k) for *"How does Tillandsias keep the
   forge isolated from the host and control outbound network access?"* ranked
   the right sections on top:
   - `enclave-network/spec.md:38-42` (Container attachment to enclave network)
   - `subdomain-routing-via-reverse-proxy/spec.md:55-60` (Router forwards to
     correct internal port)
   - enclave-startup-sequencing cheatsheets (Dependency graph; Launch forge)
4. **synthesize** (shell → qwen3-0.6b-FLM on the NPU) produced a grounded answer
   ending in a `Sources:` line echoing the section keys. *(Production fat tier =
   Qwen3-4B on the iGPU/Vulkan, separately proven in
   gpu-fat-spec-expert-2026-07-31.md — the serving tool is engine-agnostic.)*
5. **spec-envelope** (Rust) built an `answer::Envelope`, keeping ONLY the
   citations whose key the answer actually used → `confidence=retrieved`, 2
   citations.
6. **verify-answer** (independent, re-parses across the tool boundary):
   **`ok: envelope verified — 2 citation(s) resolve, confidence=Retrieved`.**

## Why it matters

This is the operator's "actually use these experts" milestone made real: a fat
RAG expert over the whole spec, answering with citations that a separate verifier
confirms resolve to real spec spans — the falsifiable contract survives local
synthesis (the crate stayed network-free; a decorative/fabricated citation is
dropped or refused). The 0.6B synthesis softened prose (small model), but
groundedness held because retrieval narrowed the corpus and the envelope only
keeps used citations — exactly the design's "retrieval narrows, synthesis
rephrases" rule.

## Verification artifacts (local scratchpad)

- `spec-index/chunks.jsonl` (10,113 chunks over the live corpus)
- `spec-index/run-rag-proof.sh` (the reproducible pipeline)
- `spec-index/sample/{chunks,vectors,top,envelope}.jsonl` + `synth.txt`
- 6 passing unit tests in `crates/tillandsias-plan/src/spec.rs`

## Residual (folds into 548/549/552 + MCP integration)

- Embedding truncation: chunks over ~512 tokens must be truncated for nomic's
  micro-batch; production should chunk smaller or use an embedder with a larger
  batch (noted for 548).
- The MCP `spec_answer` tool (fold the script into forge-plan.sh) + endpoint
  discovery + launch-state registration is the remaining 548/549 work.
- Full-corpus embed (10k chunks) is the order-552 launch/commit job, not a
  per-query cost.
