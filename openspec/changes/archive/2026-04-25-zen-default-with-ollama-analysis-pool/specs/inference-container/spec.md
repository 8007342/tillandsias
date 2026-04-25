## ADDED Requirements

### Requirement: Tier-tagged tool-capable model pre-pulls

The inference container SHALL pre-pull a tier-tagged set of tool-capable
ollama models bucketed by available CPU/GPU capacity. Tinyllama and
other non-tool-call-supporting models MUST NOT appear in any tier.

| Tier | Trigger                | Model              | Approx size |
|------|------------------------|--------------------|-------------|
| T0   | Always                 | `qwen2.5:0.5b`     | 397MB       |
| T1   | Always                 | `llama3.2:3b`      | 2.0GB       |
| T2   | GPU ≥4GB OR RAM ≥16GB  | `qwen2.5:7b`       | 4.7GB       |
| T3   | GPU ≥8GB OR RAM ≥32GB  | `qwen2.5-coder:7b` | 4.7GB       |
| T4   | GPU ≥16GB              | `qwen2.5:14b`      | 9GB         |
| T5   | GPU ≥32GB              | `qwen2.5-coder:32b`| 20GB        |

T0 and T1 SHALL be baked into the inference image at build time so the
first container start has them locally with zero network. T2+ MAY be
pulled at runtime; failures SHALL log "[inference] T<N> pull failed"
and continue (not fatal).

#### Scenario: T0 + T1 ready immediately on first attach
- **WHEN** the inference container starts for the first time
- **THEN** `ollama list` SHALL show `qwen2.5:0.5b` and `llama3.2:3b`
- **AND** they SHALL come from the image (no network call required)
- **AND** the entrypoint SHALL log "[inference] T0 (qwen2.5:0.5b) ready"
  and "[inference] T1 (llama3.2:3b) ready"

#### Scenario: Higher tiers pulled in background
- **WHEN** the host has GPU detected with ≥8GB VRAM
- **THEN** the entrypoint SHALL pull `qwen2.5:7b` and `qwen2.5-coder:7b`
  in the background
- **AND** ollama SHALL be available for inference while these pull

#### Scenario: Squid manifest-pull EOF is non-fatal
- **WHEN** runtime tier pulls hit the Squid SSL-bump EOF
- **THEN** the entrypoint SHALL log the failure with tier label and
  continue
- **AND** the inference container SHALL stay up serving whatever models
  ARE present (T0 + T1 minimum)

### Requirement: Tier classification logged once at boot

On startup the inference entrypoint SHALL log a single line summarizing
which tier was selected for runtime pulls based on detected CPU/GPU/RAM,
e.g. `[inference] tier=T1 (CPU only, 16GB RAM)` or
`[inference] tier=T3 (GPU 8GB)`. The tier label SHALL match the table
above.

#### Scenario: User reading the log knows what got pulled
- **WHEN** an operator runs `podman logs tillandsias-inference | head`
- **THEN** they SHALL see one `tier=` line that maps to the table
- **AND** subsequent `[inference] T<N> ...` lines correspond to that
  tier or below
