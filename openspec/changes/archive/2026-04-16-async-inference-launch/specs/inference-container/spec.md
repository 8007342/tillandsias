# Delta: inference-container (async launch)

## MODIFIED Requirements

### Requirement: Inference container is launched off the critical path

The system SHALL launch the inference (`tillandsias-inference`) container off the critical path of `ensure_enclave_ready()`. The forge container SHALL be permitted to start before inference is ready. Inference setup SHALL still acquire `BUILD_MUTEX` so it does not race with concurrent image builds. Forge entrypoints SHALL probe inference availability with a ≤1 s timeout and fall back to a cloud or no-LLM mode if the probe fails.

@trace spec:inference-container, spec:async-inference-launch

#### Scenario: User clicks "Attach Here" while inference is cold
- **WHEN** the user clicks "Attach Here" on a project for the first time after boot
- **AND** the inference container is not yet running
- **THEN** the launch path SHALL spawn `ensure_inference_running` as a detached background task
- **AND** the forge container SHALL start without waiting for inference to become healthy
- **AND** the elapsed time from click to forge terminal opening SHALL NOT include the inference health-check window
- **AND** an `info!` log line with `spec = "inference-container, async-inference-launch"` SHALL be emitted from the spawned task once inference becomes ready (or `warn!` on failure)

#### Scenario: Inference fails to start
- **WHEN** the spawned inference setup task returns an error
- **THEN** the forge SHALL continue to operate normally
- **AND** a `warn!` log line with `category = "capability"` and `safety = "DEGRADED: ..."` SHALL be written
- **AND** the forge entrypoint SHALL detect the unavailable inference and not block on it

#### Scenario: Forge probes inference at startup
- **WHEN** a forge entrypoint launches an LLM-using tool (opencode, etc.)
- **THEN** it SHALL run `curl -m 1 -sf http://inference:11434/api/version` to check availability
- **AND** if the probe fails, SHALL unset local-LLM env vars and fall back gracefully
- **AND** SHALL NOT block on the probe for more than 1 second
