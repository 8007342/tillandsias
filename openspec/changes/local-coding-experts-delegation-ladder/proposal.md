# Proposal — local-coding-experts-delegation-ladder

- **Story:** `1831-74sf` (desired_release v0.5, release_target `forge-local-experts-milestone`).
- **Children:**
  - `1832-5a9z` — the `local` tier
  - `1833-ytbe` — `local-delegate.sh`
  - `1834-ujsf` — the outcome ledger and the rung aggregator
  - `1835-v7vx` — the model bench and the replay set
  - `1836-pfh4` — re-tagging rows as `local`
  - `1837-t4ry` — deferred: SFT/QLoRA, only if rung 3 stalls
- **Approved by:** the operator, The Tlatoāni, 2026-10-23.

## Why

Small, mechanical packets go to Haiku today, under `methodology/distributed-work.yaml` → `cycle_batch_triage.model_tier_routing`. The fleet's own GPUs could run an open coding model on some of those packets at no frontier-token cost. Two conditions make that safe:

- **Nothing reaches git without frontier review.** The frontier session checks and commits every result.
- **Trust is earned on measured results.** Each model is promoted only by its measured acceptance and revert rates.

## What changes

- **New tier.** `implementer_tier: local` becomes a floor below haiku:
  - the field vocabulary accepts it;
  - the routing rule uses it;
  - the batch selector routes to it.

  A local row falls back to haiku when no inference endpoint answers, or when its result is rejected.
- **Local delegate.** `scripts/local-delegate.sh implement <order>` runs a bounded tool loop against `TILLANDSIAS_INFERENCE_ENDPOINT`. It:
  - may edit only the row's `owned_files`;
  - runs the row's closure command;
  - never commits.
- **Outcome ledger.** The frontier session records each outcome as a ledger token. An aggregator turns the tokens into a rung for each model and quant.
- **Bench and replay set.** One bench arm checks that a model completes a tool-call round trip. A replay set of 20 landed size:S packets measures how often a model's result is accepted.

## Rungs

| Rung | Acceptance | Revert | Also |
|---|---|---|---|
| R1 | ≥ 70% | ≤ 5% | at least 20 outcomes |
| R2 | ≥ 80% | ≤ 3% | at least 20 outcomes |
| R3 | ≥ 80% | — | frontier tokens saved is positive |
| R4 | — | ≤ 2% | over 100 outcomes |

## Non-goals

- Local models never commit, push, or touch credentials or release scope.
- Fine-tuning is deferred. It starts only if R3 stalls below 80% (1837-t4ry).
