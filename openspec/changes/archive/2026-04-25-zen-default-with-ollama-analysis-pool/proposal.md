## Why

The 0.5B local model can talk to opencode but can't follow opencode's
tool-calling protocol reliably enough to drive a real coding session
end-to-end. Larger local tool-capable models (qwen2.5-coder:7b+) are
multi-GB downloads and struggle through the Squid proxy's SSL bump
(empirically: `max retries exceeded: EOF` on manifest pulls).

Meanwhile opencode ships free Zen providers (`opencode/big-pickle`,
`opencode/gpt-5-nano`, etc.) that already speak the tool-calling protocol
correctly out of the box, route through `models.dev` (already in the
proxy allowlist), and don't need user-supplied API keys.

Split responsibilities by what each tier is good at:

- **Zen models** drive the agent loop (tool calling, plan execution,
  patches). Default. Cloud-routed but free, fast, and proven.
- **Local ollama models** are an analysis pool — sub-tasks like summarize
  this log, classify these errors, generate a commit message. No tool
  calling required. Stays in the enclave, free, private.

Down the road we'll let agents use ollama for tool calling too, but only
once we have models proven to follow opencode's tool-call schema (e.g.,
qwen2.5-coder 7B+) baked into the inference image at build time so we
sidestep the Squid manifest-pull failures.

## What Changes

### Default model routing

- The bundled `config.json` overlay sets `model: "opencode/big-pickle"`
  as default — a tool-capable Zen provider. `small_model` points at a
  fast Zen model for non-reasoning tasks (titles, classification).
- The `ollama` provider stays in the config with all currently
  enumerated models (qwen 0.5b–32b, llama 1b–8b, gpt-oss 20b) so users
  can `--model ollama/<name>` for offline analysis on demand.
- The `provider.opencode.options.baseURL` is left at default (Zen routes
  through `models.dev`).

### Tier-tagged tool-capable model pre-pulls

The inference container's entrypoint pre-pulls models bucketed by host
capability. Tinyllama (which doesn't tool-call) is replaced by tool-
capable picks at every tier:

| Tier   | Trigger                   | Model                | Size  | Tool-call? |
|--------|---------------------------|----------------------|-------|------------|
| T0     | Always (CPU baseline)     | `qwen2.5:0.5b`       | 397MB | yes (weak) |
| T1     | Always (CPU)              | `llama3.2:3b`        | 2.0GB | yes        |
| T2     | GPU ≥4GB OR RAM ≥16GB     | `qwen2.5:7b`         | 4.7GB | yes        |
| T3     | GPU ≥8GB OR RAM ≥32GB     | `qwen2.5-coder:7b`   | 4.7GB | yes        |
| T4     | GPU ≥16GB                 | `qwen2.5:14b`        | 9GB   | yes        |
| T5     | GPU ≥32GB                 | `qwen2.5-coder:32b`  | 20GB  | yes        |

T0 and T1 are baked into the inference image at build time so the first
attach has a usable analysis model with zero network. T2+ pull at
runtime where they have CPU/RAM to be useful.

### Squid pull workaround acknowledged

Until the Squid SSL-bump EOF on ollama manifests is root-caused (out of
scope for this change), the spec documents the fallback path: pull on
host, rsync into `~/.cache/tillandsias/models/`. Image-build pulls
sidestep the proxy entirely.

## Capabilities

### Modified Capabilities

- `inference-container` — adds the tier table + image-build pre-pull
  requirement.
- `default-image` — adds the model-routing default (Zen for tool calls,
  ollama for analysis).

## Impact

- **Config overlay**: `images/default/config-overlay/opencode/config.json`
  flips default to a Zen model and adds `small_model`.
- **Inference image**: `images/inference/Containerfile` adds the build-
  time pre-pull of T0+T1 (~2.4GB extra image size).
- **Inference entrypoint**: `images/inference/entrypoint.sh` updates the
  tier table to tool-capable picks; logs which tier was deemed eligible.
- **No Rust changes.**
- **No proxy/git/forge changes** beyond the existing allowlist.
