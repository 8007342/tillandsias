## ADDED Requirements

### Requirement: Default opencode model is a tool-capable Zen provider

The bundled `images/default/config-overlay/opencode/config.json` SHALL
set `model` to a tool-capable Zen model (default:
`opencode/big-pickle`) and `small_model` to a fast Zen model
(default: `opencode/gpt-5-nano`). The `ollama` provider SHALL remain
fully enumerated so users can `--model ollama/<name>` for offline
analysis tasks on demand.

Rationale: local ollama models below ~7B don't follow opencode's tool-
call protocol reliably, and ≥7B models can't pull through the Squid
SSL-bump proxy without timing out. Zen models speak tool calls
correctly out of the box and route through the already-allowlisted
`models.dev` host.

#### Scenario: First `opencode run` from a fresh attach uses a Zen model
- **WHEN** a forge container is freshly attached to a project
- **AND** the user runs `opencode run "<prompt>"` with no `--model`
- **THEN** the request SHALL go to `opencode/big-pickle` (or the
  configured Zen default)
- **AND** the run SHALL be capable of tool calling (write_file,
  bash_exec, etc.)

#### Scenario: User selects ollama for analysis
- **WHEN** the user runs `opencode run --model ollama/llama3.2:3b
  "<analysis-prompt>"`
- **THEN** the request SHALL route to the local inference container
- **AND** SHALL NOT leave the enclave network

### Requirement: Cooperative split documented in agent instructions

The bundled instructions surfaced to opencode SHALL include guidance
that ollama models are for analysis subtasks (no tool calling required)
and Zen models are for tool-driven work. Future expansion to give
ollama models tool access SHALL update this guidance and the spec
together.

#### Scenario: Agent picks the right model for the work
- **WHEN** the agent has a sub-task that's pure analysis (summarize,
  classify, extract)
- **THEN** the instructions SHALL allow it to delegate to
  `ollama/llama3.2:3b` or another local model
- **WHEN** the agent has a tool-driven task (write file, run command,
  commit)
- **THEN** the instructions SHALL keep the work on the Zen tool-caller
