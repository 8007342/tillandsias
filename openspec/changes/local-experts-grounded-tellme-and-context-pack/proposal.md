# Proposal — local-experts-grounded-tellme-and-context-pack

- **Story:** `1813-54df` (desired_release v0.5, release_target `forge-local-experts-milestone`).
- **Children, p1:** `1814-x78v`, `1815-tei4`, `1816-iyyc`, `1817-wq7y`, `1821-xcwc`.
- **Children, p2:** `1818-uiar`, `1819-njan`, `1820-m2kq`.
- **Children, p3:** `1822-dmwz`, `1823-4kwh`.
- **Related:** `965-hz3f`, `939-jxgz`, `824-6qxh`.
- **Approved by:** the operator, The Tlatoāni, 2026-10-23.

## Why

Field finding: inside a forge, `tellme howto` told the user to use `docker`. The forge has no docker and no nested container daemon. The cause is in how the system is built, not in the quality of the model:

- **tellme does not ground its answers.** `images/default/cli/tellme` is a bash RAG:
  - it finds context by keyword-grepping `/opt/cheatsheets/INDEX.md`;
  - it posts raw ollama `/api/generate` requests to `qwen2.5:0.5b`;
  - its prompt says "If the context does not contain the answer, use your general knowledge of Linux, Docker/Podman, containers…".
- **tellme bypasses the grounded pipeline.** That pipeline (`pipeline.rs` `run_grounded`, served by `expert_serve.rs` on `127.0.0.1:11436`) cites the chunks it retrieved and refuses when retrieval scores fall below its threshold. tellme never calls it.
- **No prompt knows about the forge.** No synthesis prompt anywhere carries forge context, and no single cheatsheet states the forge's hard constraints in a place retrieval can find.

Quick answers are also over budget:

- Warm 7b/14b Quick answers measured 3960–4051 ms on macuahuitl's RTX A5000, against a 3000 ms budget.
- The cause is that decomposition runs inside the Quick deadline (`939-jxgz`).
- The operator ruled on 2026-10-23 that Quick skips decomposition, as Immediate already does. This resolves `965-hz3f` criterion 1.

## What changes

1. **tellme uses expert-serve.** `howto` and free-form `about` go through expert-serve whenever the port answers. The grep path remains only as a fallback, with the general-knowledge sentence removed, and it honours `TILLANDSIAS_INFERENCE_MODEL`.
2. **Context pack.** Forge launch writes a generated, size-bounded context pack built from the project's own declarations. It goes first in every synthesis system prompt, byte-identical each time, so ollama can reuse its prefix cache.
3. **Forge-constraints cheatsheet.** `cheatsheets/runtime/forge-constraints.md` states the forge's hard constraints and is listed in the cheatsheet index.
4. **Quick skips decomposition.** Fine keeps it.
5. **Context window and budget.** Synthesis sets an explicit context window for each model size, and retrieved context is limited by a token budget instead of a chunk count.
6. **Answer cache.** expert-serve caches answers, keyed by index revision, domain and normalised query.
7. **Margin-based refusal.** Refusal uses a score margin plus a word-overlap check, calibrated on the existing refusal corpora.
8. **Forge-awareness test cases.** New groundtruth cases cover forge constraints, including a project that is not Tillandsias.
9. **Later.** Hybrid BM25 + dense retrieval merged with RRF, and one expert client shared by every front-end.

## Operator constraint

Forges also run projects other than Tillandsias, each with its own rules and branch-discipline level. The context pack therefore follows the project in the forge:

- **Built from the project's own declarations:** its discipline level, CLAUDE.md/AGENTS.md, methodology if it has one, branch, remote and toolchain.
- **Always included:** the universal forge constraints.
- **Only for Tillandsias itself:** Tillandsias-specific rules.

## Out of scope

Two related pieces of work are separate changes:

- the fleet coordinator (`fleet-coordinator-warm-cache`);
- local coding delegation (`local-coding-experts-delegation-ladder`).
