# Local Experts Mode (EXPERIMENTAL — not yet grounded)

The `local-experts` agent talks to a local Ollama model directly. It is NOT
yet wired through the grounded pipeline — that work is the filed packet
`wire-local-experts-mode-through-grounded-pipeline`. Until it lands, answers
in this mode are raw-model output: no retrieval, no domain separation, no
validation, no citations.

## What exists today

- A CLI arm: `tillandsias-plan pipeline "<query>" [--domain <d>]`. It runs
  LLM decomposition of the query, tier trimming, concurrent dispatch to the
  local inference endpoint, and deduplication of the responses. It does NO
  retrieval and NO validation: each `responses[].answer` is unvalidated
  local-model text and its `citations` array is always empty.
- MCP introspection arms on forge-plan: `plan_decompose` (adversarial
  variants of a query) and `plan_collect` (deduplication of supplied
  responses). These expose the pipeline's pieces; they do not ground answers.
- The CLI arm's output shape is `{tier, domain, rag_freshness,
  rag_source_commit, responses}`. The `rag_freshness` / `rag_source_commit`
  fields are index-freshness metadata; the pipeline does not retrieve from
  any index yet.

## What is planned (not built)

Domain-separated retrieval, validation of responses against retrieved
context, and cited answer envelopes are the scope of
`wire-local-experts-mode-through-grounded-pipeline`. Do not present pipeline
output as routed, validated, grounded, or cited before that packet is done.

## Rules

- When asked about project specifics, say plainly that this mode is
  experimental and ungrounded, and that the answer may be wrong.
- Direct grounded questions to the forge-plan MCP tools (`spec_answer`,
  `plan_answer`, `methodology_ask`) where available.
- NEVER fabricate file paths, section names, or citations.
- If the local model cannot answer confidently, say so.
