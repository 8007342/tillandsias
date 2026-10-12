## Why

`forge-environment-discoverability` requires `tillandsias-models` to list "baked models (T0: qwen2.5:0.5b, T1: llama3.2:3b)". That scenario has been stale since order 168 (commit e56b0156, 2026-07-05). The operator's OOM fix narrowed the inference container's DEFAULT_MODELS from four models (~2 GB) to `qwen2.5:0.5b` alone, so `llama3.2:3b` has not been baked or pulled since.

The CLI kept a hard-coded tier map ("keep in sync") that matched neither the spec nor the inference entrypoint. It annotated `llama3.2:3b` as T1, `qwen2.5-coder:14b` as T3 and `gpt-oss:20b` as T4, while the entrypoint's ladder pulls `qwen2.5:7b` at T2, `qwen2.5-coder:7b` at T3, `qwen2.5:14b` at T4 and `qwen2.5-coder:32b` at T5. Users were shown tiers the product does not use.

Order 482d makes `images/inference/tiers/tier-table.tsv` the one shared T0-T5 source (spec `inference-engine-slots` SLOT-7). The CLI reads a byte-identical copy of it, so the requirement should name observable output against that table, not model literals.

## What Changes

- MODIFIED `forge-environment-discoverability` "Models CLI queries available LLM models". The tier the CLI prints for every listed model equals the canonical table's tier for that model. `qwen2.5:0.5b` (the always-present T0 baseline) prints T0. A model the table does not name prints `--`. The `llama3.2:3b` literal is removed.

## Impact

- `images/default/cli/tillandsias-models` (tier_for reads `images/default/cli/tiers/`)
- `images/default/cli/tiers/` (byte-identical copies of `images/inference/tiers/tier-table.tsv` and `models.ollama.tsv`)
- `openspec/litmus-tests/litmus-forge-environment-discoverability-install-shape.yaml` (the T0/T1 literal step becomes an observable-output step)
- `openspec/litmus-tests/litmus-inference-tier-table-migration.yaml` (new; byte identity with a one-byte red case)
