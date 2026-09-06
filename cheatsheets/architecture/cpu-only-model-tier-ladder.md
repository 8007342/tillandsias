---
tags: [inference, models, tiers, cpu, ram, forge, capacity]
languages: [bash]
since: 2026-09-02
last_verified: 2026-09-02
sources:
  - plan/index.yaml order:919-vvyv
  - plan/archive/packets-2026-07.yaml order:392a
  - plan/archive/packets-2026-07.yaml order:168
  - images/inference/entrypoint.sh
  - images/inference/preload-policy.sh
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
---

# The CPU-only model tier ladder

Which local model a host can actually run, keyed on the resource it is actually
short of. **On a GPU host that is VRAM. On a CPU-only host it is RAM, and until
order 919-vvyv nothing said so** — the ladder in `images/inference/entrypoint.sh`
classifies by `max(VRAM, RAM)` and a CPU-only node simply fell to `T1` with no
model guidance attached to it, so operators and automation had nothing to select
on. This page is the readable half of that ladder.

## The ladder

`entrypoint.sh` computes the tier; this table says what each tier means when
there is **no usable GPU**, so the numbers are RAM-only.

| Tier | RAM (CPU-only) | Chat/synthesis model | What it is good for |
| ---- | -------------- | -------------------- | ------------------- |
| `T1` | `< 16 GB`      | `qwen2.5:0.5b` (the pinned default, ~400 MB) | Tool-calling and routing only. **Ungrounded answers are not usable** — see the accuracy note below. |
| `T2` | `>= 16 GB`     | `qwen2.5:7b` (~4.7 GB) | The first tier where synthesis over retrieved context is worth reading. |
| `T3` | `>= 32 GB`     | `qwen2.5:7b`, headroom for a second loaded model | Comfortable: retrieval and synthesis can hold slots concurrently. |
| `T4`/`T5` | GPU-only tiers | — | Selected by VRAM (`>= 16` / `>= 32 GB`); unreachable without a GPU. |

The embedding model is **not** tiered. `nomic-embed-text` is ~274 MB at every
tier and is pulled unconditionally (919-vvyv criterion 1), because L1 retrieval
is what makes the small tiers usable at all.

## Read the tier, do not re-derive it

Automation branches on the line the inference container already prints, and on
the accelerator envelope the forge already exports. Neither needs a probe:

```bash
podman logs tillandsias-inference | grep '^\[inference\] tier='
# [inference] tier=T2 (RAM 13GB, VRAM 8GB)
```

```bash
# Inside a forge — the host's hardware, already projected onto a closed vocabulary.
echo "$TILLANDSIAS_ACCEL_ENVELOPE"
# accel_class=cpu-only accel_gpu=present-unusable accel_reason=engine-missing accel_ram_gb=13 ...
```

`accel_class` is the field to branch on: `cpu-only` means this table applies.
When hardware is present but no engine covers it, `accel_gpu` reads
`present-unusable` and `accel_reason` names the obstruction — **that is still a
CPU-only host for model-selection purposes**, and it is the common case on a
laptop whose discrete GPU has no CDI spec.

## Why the small tiers need retrieval, with numbers

MEASURED on a CPU-only forge (order 919-vvyv, 16 cores / 13 GB):

- `qwen2.5:0.5b` — prefill 435 tok/s, generation 128 tok/s. Fast and cheap.
- **Ungrounded accuracy at T1 is zero**: both `0.5b` and `1.5b` hallucinated
  6/6 project questions asked without retrieval.

So the T1 verdict is not "a weak model" but "a model that must not be asked a
question from its own weights". This is why the pipeline refuses typed
(`confidence=unsupported`) rather than falling back to the raw model: at this
tier the raw model is worse than a refusal, because a refusal is honest.

The corollary for capacity planning: **adding RAM to a CPU-only host buys more
than a faster GPU-less model — it buys the first tier whose synthesis is worth
reading.** Below 16 GB, spend the effort on retrieval quality (L0 and L1), not
on a larger chat model that will not fit.

## Overrides

| Variable | Effect |
| -------- | ------ |
| `TILLANDSIAS_DEFAULT_MODELS` | Replaces the pulled chat set. The default literal is pinned by `litmus:zen-default-with-ollama-shape`; order 168 narrowed it to one ~400 MB model to stop a real OOM container-death on constrained hosts. |
| `TILLANDSIAS_INFERENCE_TIER_PULLS=1` | Opt in to pulling the larger tier model. Off by default (order 392a) so multi-GB models never evict the expert slots the preload policy reserves. |
| `TILLANDSIAS_EMBED_MODEL` | The embedding model name. Must match what the index was built with — a mismatch 404s and presents as a missing index (760-hzi4 defect i). |
| `TILLANDSIAS_INFERENCE_EMBED_PULL=0` | Skip the embed pull. L1 retrieval then stays unavailable unless the model is already cached. |
| `TILLANDSIAS_INFERENCE_PRELOAD` | `eager` (default) / `lazy` / `off`. |

## Related

- `cheatsheets/architecture/expert-inference-endpoint-contract.md` — which
  endpoint and which tier (L0/L1/L2) serves a question, and what each refusal
  means.
- `tillandsias-plan experts-probe` — whether the tiers are live *right now*.
