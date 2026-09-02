# Tasks — mapped to the five 920-pxg6 exit criteria

## 1. OpenSpec change BEFORE implementation (exit criterion 1)

- [x] 1.1 File this change tree (.openspec.yaml, proposal, design D1-D7,
      these tasks, delta specs) before any source edit — the facade landed
      spec-less and this repairs that.
- [x] 1.2 `specs/expert-serve-grounded-pipeline/spec.md` ADDED requirements
      R1-R6 with WHEN/THEN scenarios.
- [x] 1.3 `specs/forge-environment-discoverability/spec.md` MODIFIED delta
      pinning the `local-experts` agent to the grounded endpoint.

## 2. Refusal, not fallback (exit criterion 2)

- [x] 2.1 `run_grounded` preflight refusals: no embedding endpoint, no
      resolvable index entry, no chunks in the requested domain — each the
      pinned `Envelope::unsupported`, emitted BEFORE any model request.
- [x] 2.2 Dead-endpoint degradation: embed failure refuses typed; synthesis
      failure degrades to the CITED retrieval-only digest, never raw prose.
- [x] 2.3 HTTP front-end renders refusals verbatim as completion content
      (HTTP 200, finish_reason stop).
- [x] 2.4 `litmus-expert-serve-refusal-not-fallback.yaml`: typed refusal +
      proof of zero model requests + negative control (covered query still
      answers cited).
- [x] 2.5 Function-level test: no envelope may carry
      `confidence != unsupported` with zero citations; a refusal path makes
      zero synth-endpoint connections (counted listener).

## 3. Citations survive only if used (exit criterion 3)

- [x] 3.1 Per-variant envelopes built via the `spec::build_envelope` family
      (scored form); prose that used no retrieved key downgrades and falls
      back to the cited digest.
- [x] 3.2 Freshness + `rag_source_commit` from the index entry's `.commit`
      (801-g9nn) and `chunks.jsonl` mtime; `with_default_citation_commit`
      applied before any HEAD stamp; `Freshness::for_corpus` removed from
      this path.
- [x] 3.3 `litmus-expert-serve-citations-only-if-used.yaml`: subset-usage
      synthesis keeps only the used citation + negative control.
- [x] 3.4 Freshness honesty tests: fixture `.commit` propagates; frameless
      entry reports `unknown`.

## 4. Lua disposition (exit criterion 4)

- [x] 4.1 DELETE `validate.lua` and its dead bridge paths; validation is
      Rust (`answer::verify` in the pipeline).
- [x] 4.2 Fix `collect.lua` nil-answer crash; regression test.
- [x] 4.3 Make `tier.lua` tiers reachable; enforce budgets with
      `tokio::time::timeout` around dispatch.
- [x] 4.4 Correct `lua_runtime.rs` docs to describe only what exists — no
      re-promised phantom sandbox.
- [ ] 4.5 mlua portability evidence from the darwin/msys lanes (902-5bf9's
      blocking criterion) — OPEN: needs those hosts; the Lua surface kept
      here is deliberately thin enough to replace if evidence fails.

## 5. One pipeline, two front-ends (exit criterion 5)

- [x] 5.1 `pub async fn run_grounded(runtime, entry, cfg, query) -> Envelope`
      in pipeline.rs; delete `run_pipeline` and the hardcoded
      validated/confidence/citations paths.
- [x] 5.2 Rewrite the `pipeline` CLI arm onto `run_grounded`, emitting the
      ratified envelope.
- [x] 5.3 New `expert-serve` subcommand: tokio TcpListener on 127.0.0.1
      (default 11436), `POST /v1/chat/completions` (non-stream + SSE),
      `GET /v1/models`, 404 JSON otherwise, stdin-EOF lifetime, per-request
      entry re-resolution, pinned stderr start line.
- [x] 5.4 One HTTP client helper for ALL model calls (decompose +
      synthesis via `{base}/chat/completions`; embeddings via
      `{TILLANDSIAS_EMBED_ENDPOINT}/embeddings`); default host `inference`
      restored; both panic seams fixed.
- [x] 5.5 Hoist `SpecIndexEntry` (+ resolve ladder, arity-refusing loader)
      into a public `spec_index` module; groundtruth delegates unchanged.
- [x] 5.6 Registration: DISPATCH_ARMS, capabilities.txt (sorted),
      USAGE entry, early ledger-independent dispatch block.
- [x] 5.7 Config repoint: `tillandsias-experts` provider + `local-experts`
      agent in dev opencode.json and the forge overlay; both instruction
      files rewritten; lib-common.sh fail-soft lifecycle block; the two
      stale 902-5bf9 tool-description citations in forge-plan.sh moved to
      920-pxg6.
- [x] 5.8 `litmus-expert-serve-endpoint-shape.yaml`: OpenAI envelope shape,
      SSE `[DONE]`, `rag_source_commit == entry .commit` (not HEAD).
- [x] 5.9 `cargo test -p tillandsias-plan` green, including the three
      registration tests, domain-filter unit, OpenAI/SSE shape tests, and
      the port-0 integration test (typed refusal end-to-end, /v1/models,
      404, fast shutdown).
- [x] 5.10 Live OpenCode session verification against a running
      expert-serve — DONE on macuahuitl-tillandsias-forge 2026-09-02
      (RTX A5000, inference:11434, 22682-chunk index from b300d6b92).
      Covered -> synthesized prose with a correct `Sources:` line and
      citations narrowed 6->3 to the ones the prose used; uncovered ->
      typed `unsupported:` refusal, citations=[], naming best score
      (0.56-0.58) against the 0.62 floor. Both through the `pipeline`
      CLI arm and over the expert-serve HTTP endpoint; /v1/models,
      typed 404, `rag_source_commit` == the entry `.commit`. Required
      fixing the launch first: the forge derived the embed endpoint
      only from OLLAMA_HOST, which nothing in the forge sets, so the
      lifecycle-started server answered `unsupported: no embedding
      endpoint` with everything else in place (fixed, ea280c2d9).
      Full evidence on the 920-pxg6 events.
