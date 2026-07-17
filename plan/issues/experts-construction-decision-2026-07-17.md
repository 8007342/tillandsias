# DECISION: expert-construction technique (order 393) — SIGNED

- Date: 2026-07-17
- Decided by: **The Tlatoāni** (interactive session, verbatim: "yes, this
  reads fantastic"), with the linux coordinator's analysis
- Status: decision SIGNED; benchmark/ground-truth harness rides rung 1
  (order 394) as its grading gate

## The decision — per-corpus technique, no training anywhere

1. **METHODOLOGY EXPERT: Ollama Modelfile stuffing.** methodology.yaml
   (~250 lines) fits comfortably in a tiny model's context. Literally the
   operator's mechanic: on launch/commit, `ollama create
   tillandsias-methodology-expert` from a Modelfile embedding the fresh
   file; eviction via ollama-native `keep_alive` TTL. Zero extra infra.
2. **PLAN EXPERT: graph-aware RAG (GraphRAG-lite).** plan/index.yaml
   (~14.5k lines, 100k+ tokens) blows tiny-model context and dilutes
   attention; naive similarity retrieval is weak at RELATIONAL queries
   ("what is blocked by X" is a join, not a nearest neighbor). At index
   time we parse the YAML deterministically (it is machine-readable by
   construction) into the dependency graph; query-time retrieval pulls the
   named node + its depends_on/release_target closure into context;
   embeddings cover the prose corpora (issues, loop_status, specs). The
   flagship query class becomes deterministic — zero hallucination
   surface on edges/statuses.
3. **Serving: transparent in-container proxy.** A tiny OpenAI-compatible
   shim inside the inference container intercepts the expert model names
   (tillandsias-plan-expert, …), retrieves, forwards to ollama. Agents see
   ONLY a model name — OpenCode needs nothing but provider entries
   (order 395). Not end-user-facing.
4. **Freshness: delta re-embed + re-create on commit** (order 396) —
   seconds, not retrains.
5. **Ephemerality: tmpfs index + keep_alive eviction** — both layers die
   cleanly; nothing survives stack shutdown.
6. **Fine-tune/LoRA: REJECTED** for this use case. Tiny-model weights
   memorize style, hallucinate specifics (exact packet ids/edges — our
   core queries); per-commit retraining is cost-absurd; no offsetting
   advantage.

## Rejected-alternatives ledger

| Technique | Why not |
|---|---|
| Fine-tune/LoRA | correctness (specifics hallucinate at tiny scale), freshness cost, operator-excluded |
| Pure Modelfile for plan | context overflow + per-query prefill over the whole corpus + attention dilution at 14.5k lines |
| Pure similarity RAG for plan | weak on relational/join queries — the flagship class |
| Agent-side grep/browse (status quo) | the thing we are replacing |

## Amendment (same session): the deterministic layer is a shared engine

The Tlatoāni extended the vision: the deterministic YAML layer should be
a COMPILED query/EDIT engine (order 398) — load the tree, edit under
schema rules, flush validated, format-preserving — serving both agents
(CLI: claim/event-append/status-flip/blocked-by queries) and the PLAN
EXPERT (library backend for graph retrieval). Combined with hot-path
RAMDISK placement (order 329) and forge LSP (order 399), local knowledge
is queried locally, deterministically, from RAM.
