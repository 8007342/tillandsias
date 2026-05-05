## ADDED Requirements

### Requirement: Collect build phase metrics

The system SHALL track duration and download volumes for each phase of the forge container image build, categorizing phases by function (OS packages, tools, agents, summarizers, finalization).

#### Scenario: Package install phase metrics captured
- **WHEN** forge image build executes STEP 1-17 (OS packages and tools installation)
- **THEN** system records start timestamp, end timestamp, bytes downloaded for the phase
- **AND** calculates duration_secs = end_timestamp - start_timestamp

#### Scenario: Multi-phase aggregation
- **WHEN** forge image build completes all 80 steps
- **THEN** system emits structured JSON telemetry with array of phases, each containing { name, start_secs, end_secs, bytes_downloaded }

### Requirement: Emit optimization suggestions

The system SHALL analyze build metrics and emit human-readable suggestions to guide infrastructure investment (cache, proxy, layer reordering).

#### Scenario: Package download optimization suggestion
- **WHEN** package install phase exceeds 45% of total build time
- **THEN** system emits log event with message: "Package downloads account for {percent}% of build time — consider pre-populating mirror or enabling host proxy caching"

#### Scenario: Large download volume suggestion
- **WHEN** total download volume across build exceeds 1GB
- **THEN** system emits log event suggesting enabling Squid proxy cache to deduplicate downloads across multiple developers

#### Scenario: Slowest phase identification
- **WHEN** forge build completes
- **THEN** system identifies the single slowest phase by duration and emits log event: "Slowest phase: {phase_name} ({duration_secs}s) — consider reordering layers"

### Requirement: Structured telemetry logging

All build metrics SHALL be emitted as structured log events with spec:build-metrics tag for traceability.

#### Scenario: Metrics emitted with spec annotation
- **WHEN** ImageBuilder::build_image() completes successfully
- **THEN** system emits tracing event with fields: spec="forge-build-metrics", phase_duration_secs, download_bytes, optimization_suggestion

## Sources of Truth

- `cheatsheets/build/cargo.md` — cargo build performance analysis patterns
- `cheatsheets/build/podman.md` — podman build output parsing and metrics extraction
