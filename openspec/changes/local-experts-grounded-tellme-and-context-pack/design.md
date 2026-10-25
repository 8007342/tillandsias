# Design — local-experts-grounded-tellme-and-context-pack

Code is cited by symbol, not by line.

## 1. Request path after the change

```
tellme howto|about  ──probe 127.0.0.1:11436──► expert-serve (OpenAI-shaped)
        │ port closed                               │
        ▼                                           ▼
  grep INDEX.md fallback                run_grounded(tier, domain, query)
  (pack-first prompt,                     ├─ answer cache hit? → return
   no general-knowledge text,             ├─ decompose only on Fine
   model = TILLANDSIAS_INFERENCE_MODEL)   ├─ retrieve (dense + BM25 fused by RRF, 1822-dmwz)
                                          ├─ refuse by margin + overlap
                                          └─ synthesise: [PACK][chunks ≤ budget][question]
```

## 2. Context pack

The forge-launch path that runs `inject_startup_context` (`images/default/lib-common.sh`) writes the pack to `.forge-expert-context.md`, beside `.forge-startup-context.md`. It is git-ignored the same way.

### Size limit

- The pack is at most 4800 bytes, about 1.2k tokens.
- When it is too big, the lowest section (the project excerpt) is cut first.
- The universal constraints are never cut.

### Sections, in fixed order

1. **Universal forge constraints.** Always present. This is the summary block of `cheatsheets/runtime/forge-constraints.md`.
2. **Project identity.** Name, remote, branch, detected toolchain.
3. **Project discipline.** The level from `tillandsias-plan discipline` (0, 1 or 2) and a one-line meaning of that level.
4. **Project declarations.** A bounded excerpt of `CLAUDE.md` or `AGENTS.md` if present, and a pointer to the project's methodology if it has one.
5. **Tillandsias rules.** Included only when the project is Tillandsias. A project counts as Tillandsias only when it has both `methodology.yaml` and `crates/tillandsias-plan`. The remote name alone does not count.

### Prefix stability

Ollama can reuse its cached prompt prefix only if every synthesis prompt starts with the same bytes. Two rules make that true:

- The pack itself is deterministic: no timestamps, no per-query text, no varying order.
- Every synthesis system prompt is built the same way: the pack's exact bytes first, then a fixed separator, then the retrieved chunks. Both `domain_synthesis_prompt` (pipeline.rs) and tellme follow this.

## 3. Quick skips decomposition

- Today `run_grounded` skips the decompose branch only for `LatencyTier::Immediate`.
- After this change it also skips it for `LatencyTier::Quick`.
- Fine keeps decomposition, together with the socket-deadline cancellation from 939-jxgz.

## 4. Context window and budget

### Retrieval budget

The model id gives the size class:

| Size class | Models | Context allowed |
|---|---|---|
| Small | 0.5b, 3b | pack + at most 4 chunks |
| Large | 7b, 14b | pack + at most 8 chunks |

In both classes a token estimate (characters ÷ 4) also caps the total.

### Context window

ollama's OpenAI-compatible endpoint does not accept `options.num_ctx`. The implementer of 1818-uiar picks one of these and records the choice:

- **Native endpoint for synthesis.** Synthesis calls use native `/api/chat` with `options.num_ctx`.
- **Per-model setting.** The inference container sets the context length when it loads each model.

## 5. Answer cache

The cache sits in `ServerState` (expert_serve.rs), beside `entry_cache`.

- **Key:** resolved index entry revision, model id, normalised query.
- **Size:** bounded.
- **Contents:** answers and refusals both.
- **Invalidation:** an index refresh changes the revision, so every older entry stops matching.

## 6. Refusal

### Today

An absolute score floor plus a middle band.

### Proposed

- **Margin.** `margin = best − median(top-k)` must be large enough.
- **Word overlap.** At least one content word from the query must appear in the best chunk.
- **Floor kept.** The existing floor stays as a hard lower bound.

### Adoption test

Run both rules on `scripts/refusal-calibration/*`, following the 824-6qxh measurements. Compare two rates:

- false answers on questions outside the corpus;
- false refusals on questions inside it.

The margin rule is adopted only if both rates are equal to or lower than the floor rule's.

## 7. Risks

| Risk | Mitigation |
|---|---|
| A pack that grows with the project makes every prompt larger. | The hard size limit and the fixed cut order. |
| A project is wrongly detected as Tillandsias, so its forge gets Tillandsias rules. | Detection needs two markers, and the groundtruth case for a project that is not Tillandsias (1821-xcwc) tests it. |
