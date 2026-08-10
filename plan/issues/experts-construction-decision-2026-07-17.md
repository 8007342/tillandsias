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

## macOS lane measurements (order 401, 2026-08-10, VZ guest — first live numbers)

Measured on the aarch64 Fedora 44 VZ guest (4 vCPU clamp, 3.9 GB RAM), inside
`tillandsias-inference` (ollama 0.32.6, self-installed at first successful
egress; binary + models persist across container recreation via the models
volume; preload policy had already fetched `qwen2.5:0.5b`):

| Metric (qwen2.5:0.5b, cpu-ollama) | Value |
|---|---|
| ollama API ready after lane bring-up | 15 s |
| model load (cold) | 2.47 s |
| cold generation, 64 tok (incl. load + prompt) | 19.2 s wall |
| warm generation throughput | ~52 tok/s (48 tok / 0.917 s; repeat 45 / 0.867 s) |
| warm end-to-end wall (48-tok answer) | ~1.2 s |
| guest RAM in use during serve | 1.4 / 3.9 GB |
| Modelfile expert build (`/api/create`, FROM + SYSTEM) | < 1 s |
| Modelfile expert first answer (cold load) | 19.5 s wall; coherent |

**Lane decision (macOS): cpu-ollama.** It is the only backend present in the
aarch64 inference image today — `llama-server`/`llama-cli` are absent
(`NO-LLAMA-SERVER-IN-IMAGE`), so the llama.cpp comparison is blocked on the
order-482b image variant; re-measure when that lands. cpu-ollama's warm
~52 tok/s on a 0.5b model is comfortably interactive for expert answers, and
cold-load (~2.5 s + first-eval warmup) argues for the eager preload policy
already configured. Consistent with this doc's construction decision, the
deterministic compiled engine remains the primary expert; the model lane is
the fallback/generative tier.

Operational caveats recorded on the 401/635 ledger entries: the enclave
network only exists after a lane bring-up (a bare `podman start
tillandsias-inference` on a fresh boot fails), and the ollama CLI is not on
the exec PATH — use the HTTP API (`/api/create`, `/api/generate`) from inside
the container.
