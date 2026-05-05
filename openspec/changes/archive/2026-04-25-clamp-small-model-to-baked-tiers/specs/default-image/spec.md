## MODIFIED Requirements

### Requirement: Default opencode model is a tool-capable Zen provider

The bundled `images/default/config-overlay/opencode/config.json` SHALL
set `model` to a tool-capable Zen model (default:
`opencode/big-pickle`). `small_model` SHALL be clamped at runtime to a
model that is **image-baked** in the inference container — either
`ollama/qwen2.5:0.5b` (T0, always baked) or `ollama/llama3.2:3b` (T1,
always baked) — regardless of detected GPU tier.

Claiming a larger tier-tagged model in `small_model` when that model
isn't in the inference cache leaves opencode's sub-tasks pointing at a
model that doesn't exist. Squid's SSL-bump can't reliably pull the big
ollama manifests at runtime (see project memory `project_squid_ollama_eof`),
so tier-upgrades past T1 are a user-driven opt-in via
`--model ollama/<name>` after they've manually pulled what they want.

The `ollama` provider SHALL remain fully enumerated in the config so
users can select any enumerated model on demand.

#### Scenario: Ultra-tier host uses the baked T1 model for analysis
- **WHEN** the host has a GPU classified as Ultra (>=12GB VRAM) and the
  tray patches the config overlay
- **THEN** `small_model` SHALL be `ollama/llama3.2:3b` (baked T1), NOT
  `ollama/qwen2.5:14b` or any other non-baked model
- **AND** opencode sub-tasks SHALL succeed on a freshly-attached project
  with no manual model pulls

#### Scenario: First `opencode run` from a fresh attach uses a Zen model
- **WHEN** a forge container is freshly attached to a project
- **AND** the user runs `opencode run "<prompt>"` with no `--model`
- **THEN** the request SHALL go to `opencode/big-pickle` (or the
  configured Zen default)
- **AND** the run SHALL be capable of tool calling (write_file,
  bash_exec, etc.)

#### Scenario: User opts into a larger model
- **WHEN** the user manually runs `ollama pull qwen2.5:14b` inside the
  inference container
- **AND** later runs `opencode run --model ollama/qwen2.5:14b
  "<prompt>"`
- **THEN** the request SHALL route to that model
- **AND** the clamp SHALL NOT interfere — the clamp only affects the
  default `small_model`, not explicit `--model` overrides
