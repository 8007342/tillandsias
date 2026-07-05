# Impl: pull default small models on inference FIRST_RUN — 2026-07-04

- class: enhancement (inference)
- filed: 2026-07-04
- owner: linux
- status: pending (blocked on model-selection research + O1-O3 sign-off)
- depends_on: inference-firstrun-small-models-research-2026-07-04.md
- trace: spec:inference-container, spec:async-inference-launch

## Scope

On the inference container's first run, pull the operator-approved default small
models into the persistent models cache (`~/.cache/tillandsias/models/`, already
mounted), idempotently and off the critical path:

1. First-run step in the inference entrypoint: for each model in the default set
   (config-overridable via `TILLANDSIAS_DEFAULT_MODELS`), `ollama list | grep -q`
   → skip if present; else `ollama pull <model>`.
2. Run async / non-blocking (async-inference-launch spec): the container serves as
   soon as ollama is up; model pulls proceed in the background and each becomes
   available as it lands. A launch never blocks on a multi-GB pull.
3. Persist into the mounted models cache so subsequent launches are no-ops.
4. Fail soft: a failed pull logs + retries next launch; other models still pull.
5. Egress through the enclave proxy; ensure the ollama registry host is
   allowlisted (delta if denied).

## Idempotency contract
- Second launch with the cache populated pulls nothing (fast no-op).
- Changing `TILLANDSIAS_DEFAULT_MODELS` adds the new models on next launch without
  re-pulling existing ones.

## Exit criteria
- Fresh inference container (empty models cache) ends up with the default set
  available via `ollama list`; models persist across restart.
- Second launch pulls nothing (idempotency litmus).
- Serving is not blocked by the pulls (async).
- `./build.sh --check` passes; a forge agent can invoke a default local model.

## DONE 2026-07-04

`images/inference/entrypoint.sh` now pulls the default 0.3-1.5B set on FIRST_RUN
via a config-driven idempotent loop:
`DEFAULT_MODELS="${TILLANDSIAS_DEFAULT_MODELS:-qwen2.5:0.5b qwen2.5:1.5b llama3.2:1b qwen2.5-coder:1.5b}"`
— replacing the old hardcoded baseline that pulled `llama3.2:3b` (3B, out of
envelope). Idempotent (`ollama list` cached-guard → skip), non-fatal per model,
into the persistent host-mounted models cache. Pinned by
`litmus:inference-firstrun-default-models-shape` (4/4: config-overridable +
idempotent-guard + default-set-in-0.3-1.5B-envelope + coder-model-present) and
updated the stale `inference-container-implementation-shape` STEP 7 (which pinned
the old T0/T1 label structure) to the loop-based non-fatal handler.

Verify at runtime (next inference launch): fresh cache pulls the set; second launch
pulls nothing; `ollama list` shows all four. NOTE: the pre-existing
`inference-container-implementation-shape` STEP 8 (build_inference_run_args proxy
env) remains red — pre-existing debt on the WIP-dirty main.rs, unrelated to this.
