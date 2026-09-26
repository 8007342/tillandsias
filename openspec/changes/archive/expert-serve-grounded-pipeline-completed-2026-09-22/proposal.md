# Proposal: expert-serve — one grounded pipeline, two front-ends

## Why

Commit 687eb6d57 ("wire local expert system") shipped a facade, and the audit
of it is the direct provenance of this change (order 920-pxg6). What the audit
found, span by span:

- The `pipeline` CLI arm did no retrieval and no validation, yet stamped every
  response `validated: true` with `confidence: 0.5` and `citations: []`
  (pipeline.rs, the hardcoded `responses_for_lua` block), and stamped
  `rag_source_commit` from `Freshness::for_corpus(repo)` — the process's own
  HEAD — for an index it never read.
- The `local-experts` OpenCode agent pointed straight at a raw Ollama model
  (`ollama/qwen2.5:14b`), so its answers were unretrieved, unvalidated,
  uncited model prose, papered over with an EXPERIMENTAL disclaimer.
- `validate.lua` promised citation validation but was dead code: it returns a
  module table the loader discards, and no Rust bridge ever called it.
- `lua_runtime.rs`'s own module doc contradicted its code about what the
  sandbox blocks, and promised bridge functions (`expert.query`, `fs.read`)
  that do not exist.
- `tier.lua` classified almost every query into one tier, and no budget was
  ever enforced around dispatch.
- `collect.lua` crashed on a response with a nil `answer`.

Order 920-pxg6 replaces the facade with the real thing: ONE grounded pipeline
(`run_grounded`) that retrieves only from the published content-addressed
spec index, keeps only citations the synthesized answer actually used, and
otherwise returns the typed `unsupported:` refusal — served through TWO
front-ends, the rewritten `pipeline` CLI arm and a new OpenAI-compatible
loopback server (`expert-serve`) that OpenCode's `local-experts` agent talks
to instead of the raw model.

## What Changes

- **New `spec_index` module** in `crates/tillandsias-plan` — the private
  groundtruth.rs helpers (879-gidx resolve ladder, 394d loader with the
  vectors/chunks arity refusal) hoisted into public infrastructure as
  `SpecIndexEntry { dir, chunks, vectors, commit, model, prefix }` +
  `load()`; groundtruth delegates, grade behavior unchanged.
- **Rewritten `pipeline` module** — `pub async fn run_grounded(runtime,
  entry, cfg, query) -> Envelope`: tier classify → LLM decomposition (with
  fallback-to-original) → tier trim → per-variant embed / domain-filtered
  top-k / grounded synthesis / envelope-with-only-used-citations (cited
  retrieval-only fallback on synthesis failure) → Rust validation → Lua
  collect merge → best cited envelope or `Envelope::unsupported`. All model
  calls converge on one HTTP client helper posting
  `{base}/chat/completions`; embeddings post
  `{TILLANDSIAS_EMBED_ENDPOINT}/embeddings`.
- **New `expert-serve` subcommand** — hand-rolled HTTP/1.1 on a tokio
  `TcpListener` bound 127.0.0.1 (default port 11436, precedent
  `crates/tillandsias-static-server`), serving `POST /v1/chat/completions`
  (non-stream and SSE) and `GET /v1/models`; refusals rendered verbatim as
  completion content with HTTP 200 / `finish_reason: stop`.
- **Lua disposition** — `validate.lua` deleted (validation is Rust);
  `tier.lua` tiers made reachable and budgets enforced via
  `tokio::time::timeout` around dispatch; `collect.lua` nil-answer crash
  fixed; `lua_runtime.rs` docs corrected to describe only what exists.
- **Config repoint** — dev `opencode.json` and the forge overlay config gain
  a `tillandsias-experts` provider (`@ai-sdk/openai-compatible`, baseURL
  `http://127.0.0.1:11436/v1`, model ids all/spec/code/methodology/
  cheatsheet); the `local-experts` agent moves to `tillandsias-experts/all`
  with an honest grounded prompt; both instruction files rewritten;
  `lib-common.sh` starts `expert-serve` fail-soft beside
  `ensure_forge_experts`, gated on a capabilities probe.
- **Citation hygiene** — the two stale `order 902-5bf9` citations in
  forge-plan.sh's `plan_decompose`/`plan_collect` tool descriptions repointed
  to 920-pxg6.

## Capabilities

### New Capabilities
- `expert-serve-grounded-pipeline`: one grounded retrieval+synthesis
  pipeline with an answer-or-typed-refusal contract, exposed through the
  CLI `pipeline` arm and the OpenAI-compatible `expert-serve` loopback
  endpoint.

### Modified Capabilities
- `forge-environment-discoverability`: the `local-experts` OpenCode agent is
  required to point at the grounded loopback endpoint, never at a raw model
  — its answers are cited envelopes or typed refusals.

## Impact

- New files: `crates/tillandsias-plan/src/spec_index.rs`,
  `crates/tillandsias-plan/src/expert_serve.rs`, three
  `openspec/litmus-tests/litmus-expert-serve-*.yaml` tests.
- Modified: `crates/tillandsias-plan/src/{pipeline,semantic_expert,
  groundtruth,lua_runtime,spec,lib,main}.rs`, `capabilities.txt`,
  `lua/{tier,collect}.lua` (validate.lua deleted), `opencode.json`,
  `images/default/config-overlay/opencode/config.json`,
  `.opencode/instructions/local-experts.md`,
  `images/default/config-overlay/opencode/instructions/model-routing.md`,
  `images/default/config-overlay/mcp/forge-plan.sh` (two citation lines),
  `images/default/lib-common.sh` (expert-serve lifecycle block).
- The `pipeline` CLI arm's output changes from the ungrounded
  `{tier, domain, rag_freshness, rag_source_commit, responses}` JSON to the
  ratified answer envelope. The old shape was documented as ungrounded and
  its only documented consumers are the instruction files updated here.
- Lua's sanctioned future (litmus steps in Lua) is order 902-5bf9,
  entry-gated on mlua portability evidence — deliberately NOT this change.

## Sources of Truth

- `openspec/changes/expert-serve-grounded-pipeline/specs/expert-serve-grounded-pipeline/spec.md`
  (the ADDED requirements R1-R6)
- `crates/tillandsias-plan/src/pipeline.rs` (`run_grounded` — the one
  pipeline both front-ends call)
- `crates/tillandsias-plan/src/spec_index.rs` (`SpecIndexEntry` — the only
  retrieval source)
- `plan/index.yaml` order 920-pxg6 (packet + exit criteria); order 902-5bf9
  (Lua litmus-steps future, mlua portability criterion)
- The 687eb6d57 facade audit (this proposal's Why) — recorded against order
  920-pxg6 in the plan ledger.
