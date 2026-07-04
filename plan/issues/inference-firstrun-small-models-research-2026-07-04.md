# Research: default small models to pull on inference FIRST_RUN (0.3-1.5B) — 2026-07-04

- class: research (inference)
- filed: 2026-07-04
- owner: linux
- status: ready
- trace: spec:inference-container, crates/tillandsias-core/src/container_profile.rs (models cache)
- goal: operator directive — download a few 0.3-1.5B general-purpose free open-source models by default on first run, made available inside the inference container; foundation for fine-tuning + piggy-backing agents that diagnose local build tests.

## Context / persistence already exists

`container_profile.rs` mounts a **models cache** dynamically at launch from
`~/.cache/tillandsias/models/` (L488-501: "The model cache is mounted dynamically
at launch time from `~/.cache/tillandsias/models/`"), and inference reaches ollama
at `OLLAMA_HOST=http://inference:11434`. So the PERSISTENT target for pulled
models already exists — first-run `ollama pull` into that cache survives restarts.
(Confirm with `podman inspect tillandsias-inference` `.Mounts`.)

## Recommended default model set (all ollama-pullable, ~0.3-1.5B, permissive)

Pick a small, general-purpose spread plus one code model (for the "diagnose local
build tests" use case). All are free/open-weight and pull via `ollama pull`:

| Model (ollama tag) | Params | License | Role |
|---|---|---|---|
| `qwen2.5:0.5b` | 0.5B | Apache-2.0 | tiny general-purpose; fastest, lowest RAM |
| `qwen2.5:1.5b` | 1.5B | Apache-2.0 | stronger general-purpose default |
| `llama3.2:1b` | 1.24B | Llama-3.2 community | general-purpose, Meta lineage |
| `qwen2.5-coder:1.5b` | 1.5B | Apache-2.0 | code/diagnostics (build-test triage) |

Optional fully-Apache fallback: `tinyllama:1.1b` (1.1B, Apache-2.0) if a Llama-
license model must be avoided. Total on-disk ~3-4 GB (Q4 quant) — acceptable for a
one-time first-run pull into the persistent models cache.

Rationale: Qwen2.5 small models are the strongest quality-per-param in this range
and are Apache-2.0 (clean for fine-tuning + redistribution); llama3.2:1b adds
lineage diversity; qwen2.5-coder:1.5b directly serves the forge-diagnostics goal.
Keep the default set SMALL (the operator said "a few"); the list is a config knob.

## Open decisions (operator sign-off)
- **O1 — exact default set + count.** Recommend the 4 above (or 3 if trimming the
  coder). Confirm the Llama-license inclusion is acceptable, or go all-Apache
  (`qwen2.5:0.5b`, `qwen2.5:1.5b`, `qwen2.5-coder:1.5b`, `tinyllama:1.1b`).
- **O2 — pull timing/policy.** First-run only (pull if absent in the models
  cache), async off the critical path (async-inference-launch spec), and a config
  override (`TILLANDSIAS_DEFAULT_MODELS`) so operators can change the set without
  a rebuild.
- **O3 — egress.** `ollama pull` fetches from ollama.com/registry.ollama.ai;
  confirm these are proxy-allowlisted (file a delta if denied).

## Verifiable closure (research done-when)
- Persistence confirmed (`podman inspect` shows the models cache mount).
- Default set chosen with operator sign-off (O1), pull policy decided (O2), egress
  allowlist verified/filed (O3).
- Impl packet (inference-firstrun-small-models-impl) shaped with the chosen set +
  an idempotency litmus (second launch pulls nothing).
