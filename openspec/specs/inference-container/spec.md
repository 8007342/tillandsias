<!-- @trace spec:inference-container -->
# inference-container Specification

## Status

status: active

## Purpose

Shared ollama inference container on the enclave network. Forge containers query it via OLLAMA_HOST. Models persist in a host-mounted cache volume. Downloads route through the proxy.
## Requirements
### Requirement: Local LLM inference via ollama
The system SHALL run an inference container with ollama on the enclave network. Forge containers SHALL access it via `OLLAMA_HOST=http://inference:11434`. The inference container SHALL use the proxy for model downloads.

@trace spec:inference-container

#### Scenario: Forge queries local model
- **WHEN** a forge container runs an ollama query via `OLLAMA_HOST`
- **THEN** the request SHALL reach the inference container over the enclave network
- **AND** the response SHALL be returned to the forge container

#### Scenario: Model download through proxy
- **WHEN** ollama needs to download a model
- **THEN** it SHALL use `HTTP_PROXY`/`HTTPS_PROXY` to route through the proxy container
- **AND** the proxy SHALL allow traffic to ollama.com

### Requirement: Shared model cache
Models SHALL be stored in a persistent volume at `~/.cache/tillandsias/models/` on the host, mounted into the inference container at `/home/ollama/.ollama/models/`.

@trace spec:inference-container

#### Scenario: Model persists across restarts
- **WHEN** the inference container is stopped and restarted
- **THEN** previously downloaded models SHALL be available immediately

### Requirement: Inference container lifecycle
The inference container SHALL be started on-demand and shared across all projects. It SHALL be stopped on app exit.

@trace spec:inference-container

#### Scenario: Inference auto-start
- **WHEN** a forge container is launched and the inference container is not running
- **THEN** the system SHALL start the inference container on the enclave network

#### Scenario: Inference cleanup on exit
- **WHEN** the Tillandsias application exits
- **THEN** the inference container SHALL be stopped

### Requirement: Inference NO_PROXY covers loopback + enclave peers

The inference container SHALL have `NO_PROXY` (and the lowercase `no_proxy`)
env variable set to a value that includes `localhost,127.0.0.1,0.0.0.0,::1`
plus every enclave-internal peer (`inference,proxy,git-service`). Without this,
ollama's own loopback health probes and peer probes hairpin through the Squid
proxy and fail with `TCP_DENIED/403`, causing model load stalls.

#### Scenario: Ollama boot health probe succeeds
- **WHEN** ollama inside the inference container probes its own listen
  address at startup (`HEAD http://0.0.0.0:11434/` or
  `GET http://127.0.0.1:11434/api/version`)
- **THEN** the Go HTTP client sees the destination match `NO_PROXY`
- **AND** the probe connects directly to ollama's socket (does not traverse the
  proxy)
- **AND** the proxy log records no `HEAD http://0.0.0.0:11434/` or
  `GET http://127.0.0.1:11434/*` denial

#### Scenario: Inference profile has NO_PROXY set
- **WHEN** the host constructs the `podman run` args for the inference
  container
- **THEN** the profile includes `NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service`
  (or a superset) as an `-e` arg
- **AND** the lowercase `no_proxy` is set to the same value
- **AND** both are passed to ollama alongside the existing `HTTP_PROXY` /
  `HTTPS_PROXY` entries

> ✅ Resolved 2026-05-31: `build_inference_run_args` now sets
> `HTTP_PROXY=http://proxy:3128`, `HTTPS_PROXY=http://proxy:3128`
> (lowercase variants too), `NO_PROXY`, and `no_proxy` using the
> same derived `enclave_no_proxy()` helper that the forge containers
> use (`localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service`
> plus the configured enclave subnet; default `10.0.42.0/24`).
> Ollama model pulls now route through the Squid proxy with SSL-bump.
> The `inference_profile()` env_vars in
> `container_profile.rs` remain declared but unconsumed by the
> launch path — the args-based encoding in `build_inference_run_args`
> is the canonical path.

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

T0 and T1 SHALL be pulled at container startup (entrypoint time, not image
build time) so image build stays fast (<30s). The entrypoint pulls them on
first container start; subsequent starts load them from a host-mounted cache
volume (~/.cache/tillandsias/models/) with zero network latency. T2+ MAY be
pulled at runtime if the host has sufficient capacity; failures SHALL log
"[inference] T<N> pull failed" and continue (not fatal).

This deferred-pull design avoids blocking build on 2-3GB downloads and
sidesteps Squid SSL-bump EOF issues (see: project_squid_ollama_eof.md).

#### Scenario: T0 + T1 pulled on first container start
- **WHEN** the inference container starts for the first time
- **THEN** the entrypoint SHALL pull `qwen2.5:0.5b` (T0) and `llama3.2:3b` (T1)
- **AND** the entrypoint SHALL log "[inference] Pulling T0 ..." and "[inference] T0 ready"
- **AND** after completion, `ollama list` SHALL show both models
- **AND** total startup time SHALL be ≤3 min (typical ~90s on 100 Mbps internet)

#### Scenario: T0 + T1 cached on subsequent starts
- **WHEN** the inference container starts with models already in the cache volume
- **THEN** the entrypoint SHALL skip network pulls
- **AND** the entrypoint SHALL log "[inference] T0 ready (cached)" and "[inference] T1 ready (cached)"
- **AND** startup time SHALL be <5s (no network, pure cache load)

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

### Requirement: CPU tier-S is the always-available terminal

The CPU lane running the T0 model (`qwen2.5:0.5b`) is designated **tier-S**,
the safety terminal. Tier-S SHALL be available on every host regardless of
GPU, NPU, driver, or engine availability, and SHALL NOT be gated on any
device probe.

`spec:inference-policy-router` terminates every fallback chain here. No
change to this spec may remove tier-S or make it conditional.

@trace spec:inference-container

#### Scenario: Tier-S serves when every accelerator is unavailable
- **WHEN** the host has no usable GPU and no usable NPU
- **THEN** the inference container SHALL still serve the T0 model on the CPU
  lane
- **AND** the tier line SHALL still be logged

### Requirement: NPU tier rows are additive and engine-gated

NPU execution SHALL be described by additional rows that supplement, and never
replace, the T0–T5 rows above. A host with a usable NPU still resolves a
T-row for its container-resident CPU/GPU lane.

| Row | Trigger | Model class | Ceiling |
|-----|---------|-------------|---------|
| N1  | `spec:accel-capability-probe` reports an NPU with `usable: true` AND device-visible memory ≥8GB | ≤4B-parameter instruct model, graph-compiled, INT4/INT8 | engine-declared context ceiling |
| N2  | `usable: true` NPU AND device-visible memory ≥16GB | ≤8B-parameter instruct model, graph-compiled, INT4 | engine-declared context ceiling |

Binding rules for the N rows:

1. An N row SHALL only be selected when the capability probe reports that NPU
   `usable: true`. A present-but-unusable NPU SHALL select no N row.
2. N rows name a **model class** (parameter ceiling plus quantization), not an
   ollama tag, because NPU engines consume graph-compiled artifacts rather
   than ollama manifests.
3. N rows SHALL NOT be attempted on the `ollama` engine kind. Ollama cannot
   use any NPU; the N rows belong to the `llama-server` or
   `host-native-sidecar` kinds of `spec:inference-engine-slots`.
4. No row above 8B parameters SHALL be added until an engine lane demonstrates
   it. The 8B parameter and 8K context ceilings reflect what the Intel NPU
   OpenVINO GenAI lane supports today; an engine that declares a larger
   context (for example the XDNA2 FastFlowLM lane) may exceed the context
   ceiling but not the parameter ceiling.
5. N-row selection SHALL be a no-op that logs and continues when no NPU is
   present, exactly as the T-row logic degrades.

@trace spec:inference-container

#### Scenario: Usable NPU with 16GB unified memory selects N2
- **WHEN** the capability probe reports an NPU with `usable: true` and a
  device-visible pool of 16GB
- **AND** the active slot is a `llama-server` or host-native sidecar kind
- **THEN** the N2 row SHALL be eligible
- **AND** the T-row for the CPU/GPU lane SHALL remain resolved unchanged

#### Scenario: Present-but-unusable NPU selects no N row
- **WHEN** an accel device is enumerated but reported `usable: false`
- **THEN** no N row SHALL be selected
- **AND** the container SHALL start normally on its T row

#### Scenario: N rows are never attempted on ollama
- **WHEN** the active engine kind is `ollama`
- **THEN** no N row SHALL be attempted

### Requirement: Tier classification logged once at boot

On startup the inference entrypoint SHALL log a single line summarizing
which tier was selected for runtime pulls based on detected CPU/GPU/RAM,
e.g. `[inference] tier=T1 (CPU only, 16GB RAM)` or
`[inference] tier=T3 (GPU 8GB)`. The tier label SHALL match the T0–T5
table above.

The entrypoint SHALL additionally log exactly one `npu=` line next to the
`tier=` line on every boot, whether or not an NPU is present, so an operator
reading `podman logs` can tell the difference between "no NPU", "NPU present
but not passed through", and "NPU present and usable". The line SHALL name
the resolved driver and device node when one is visible, and the
`unusable_reason` when the device is present but unusable, e.g.
`[inference] npu=none`, `[inference] npu=amdxdna:/dev/accel/accel0 usable=false reason=engine-missing`,
or `[inference] npu=intel_vpu:/dev/accel/accel0 usable=true`.

@trace spec:inference-container

#### Scenario: User reading the log knows what got pulled
- **WHEN** an operator runs `podman logs tillandsias-inference | head`
- **THEN** they SHALL see one `tier=` line that maps to the table
- **AND** subsequent `[inference] T<N> ...` lines correspond to that
  tier or below

#### Scenario: NPU state is legible on every boot
- **WHEN** an operator runs `podman logs tillandsias-inference | head`
- **THEN** they SHALL see exactly one `npu=` line
- **AND** on a host with no accel device that line SHALL read
  `[inference] npu=none`
- **AND** on a host with a device passed through it SHALL name the driver and
  device node

### Requirement: The engine behind the endpoint is a slot

The inference container is one engine slot behind the enclave inference
endpoint, not the endpoint itself. `spec:inference-engine-slots` governs which
engine is bound, the descriptor a slot declares, and the host-native sidecar
lane. `spec:accel-capability-probe` governs what devices exist and whether
they are usable. `spec:inference-policy-router` governs which slot and tier
serve a given request.

The `OLLAMA_HOST=http://inference:11434` consumer contract stated above
SHALL remain valid regardless of which slot is bound.

@trace spec:inference-container

#### Scenario: Consumer contract survives an engine change
- **WHEN** the active engine slot changes
- **THEN** `OLLAMA_HOST=http://inference:11434` SHALL still resolve for forge
  containers


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation` — Verify inference container is enclave-only with no external network access
- `litmus:inference-readiness-probe-shape` — Verify the stack uses container health plus a forge-side `/api/version` probe
- `litmus:inference-engine-slot-boundary-shape` — Verify the NPU tier rows, the tier-S terminal, and the host-native sidecar isolation clauses have not been weakened

Gating points:
- CPU tier-S (T0 on CPU) is unconditional and present in the spec
- NPU rows N1/N2 are additive, probe-gated, and never attempted on the ollama engine kind
- Exactly one `npu=` line is logged at boot alongside `tier=`
- Container named `tillandsias-inference` starts from `tillandsias-inference` image
- Container attaches to `tillandsias-enclave` network only; no default bridge access
- Container exposes the friendly alias `inference` on the enclave network
- ollama listens on `http://127.0.0.1:11434` (localhost only, not accessible from forge)
- Forge containers reach ollama via proxy at `http://ollama-proxy:3128` with `OLLAMA_HOST=http://inference:11434`
- GPU tier detection runs on startup and logs `tier=<none|low|mid|high|ultra>`
- T0 models baked into image; T1+ models pulled on demand
- No outbound network access to ollama.ai or huggingface (air-gapped)

## Sources of Truth

- `cheatsheets/runtime/local-inference.md` — Local Inference reference and patterns
- `cheatsheets/runtime/container-gpu.md` — Container GPU reference and patterns
- `docs/memory/project_squid_ollama_eof.md` — Squid 6.x SSL-bump EOF workaround justification (deferred model pulls avoid EOF)

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:inference-container" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
