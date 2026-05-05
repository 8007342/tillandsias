## ADDED Requirements

### Requirement: Build metrics collection during init

The `tillandsias --init` command SHALL collect and emit build phase metrics during forge image construction, categorizing phases by function and tracking duration and download volumes.

#### Scenario: Metrics collected during image build
- **WHEN** `tillandsias --init` executes the forge image build
- **THEN** the system records start and end timestamps for each major phase (packages, tools, agents, summarizers, finalization)
- **AND** aggregates bytes downloaded for each phase from podman build output parsing

#### Scenario: Metrics emitted at build completion
- **WHEN** forge image build completes successfully
- **THEN** system emits structured JSON telemetry containing array of build phases with { name, start_secs, end_secs, bytes_downloaded }
- **AND** logs this telemetry with spec: "forge-build-metrics" for traceability

### Requirement: Optimization suggestions

The `tillandsias --init` command SHALL analyze build metrics and emit actionable optimization suggestions to guide infrastructure investment.

#### Scenario: Package cache optimization suggestion
- **WHEN** forge image build completes and package install phase exceeds 45% of total duration
- **THEN** system prints to stdout: "📦 Package downloads account for {percent}% of build time — consider pre-populating local mirror or enabling Squid proxy cache"

#### Scenario: Large download optimization suggestion
- **WHEN** forge image build completes and total download volume exceeds 1GB
- **THEN** system prints to stdout: "📥 Total downloads: {GB}GB — consider enabling Squid proxy caching to deduplicate across developers"

#### Scenario: Slowest phase identification
- **WHEN** forge image build completes
- **THEN** system prints to stdout: "⏱️ Slowest phase: {phase_name} ({duration_secs}s) — consider reordering Containerfile layers to fail faster"
