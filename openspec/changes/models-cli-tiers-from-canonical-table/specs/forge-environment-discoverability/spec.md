## MODIFIED Requirements

### Requirement: Models CLI queries available LLM models

The forge MUST provide a `tillandsias-models` command that queries the inference service and lists available language models with their capabilities. The tier the command prints for a model MUST come from the canonical T0-T5 tier table (`images/inference/tiers/tier-table.tsv`, spec `inference-engine-slots` SLOT-7), never from a list kept in the CLI.

> Delta: the previous scenario named "baked models (T0: qwen2.5:0.5b, T1: llama3.2:3b)". `llama3.2:3b` stopped being baked at order 168 (commit e56b0156, the OOM fix that narrowed DEFAULT_MODELS to `qwen2.5:0.5b`), and the CLI's own hard-coded map had drifted from the inference entrypoint. The scenarios now state observable output against the canonical table.

#### Scenario: Agent discovers model inventory
- **WHEN** a user runs `tillandsias-models` inside the forge
- **THEN** the command outputs models accessible via the inference container, including the always-present baseline and any pulled models
- **AND** each entry includes model name, size, tier classification
- **AND** for every model listed, the tier printed equals the canonical table's tier for that model
- **AND** `qwen2.5:0.5b`, the always-present T0 baseline, prints `T0`
- **AND** a model the canonical table does not name prints `--`

#### Scenario: Models CLI stays machine-readable
- **WHEN** a user runs `tillandsias-models --json`
- **THEN** the output is machine-readable JSON
- **AND** each model carries the same tier the human-readable output prints (T0 = the always-present baseline, T1-T5 = the classification ladder, `--` = not in the canonical table)
