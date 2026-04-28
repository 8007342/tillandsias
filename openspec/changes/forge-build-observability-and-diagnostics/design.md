## Context

The forge image build is a 6.5GB, 80-step container build that takes 2+ hours on modern hardware. Every build step is identical (no incremental caching across builds). Today, users receive no feedback during builds and no visibility into which phases are slowest or which components consume the most resources. Runtime failures require manual container inspection (podman exec, tail logs) after the fact.

Current build flow:
1. `init --init` calls `ImageBuilder::build_image()`
2. `build_image()` invokes `podman build` with inherited stdio (recent fix provides real-time output)
3. Build completes or fails silently
4. No metrics collected; users unable to identify optimization targets
5. Runtime issues require manual investigation

## Goals / Non-Goals

**Goals:**
- Collect granular metrics on build phase durations and download volumes
- Identify slowest and largest build phases to guide optimization
- Emit structured telemetry (JSON) that can guide cache/proxy investment decisions
- Enable real-time multi-container log streaming for diagnosing runtime issues without SSH
- Provide developers with actionable optimization suggestions immediately after build

**Non-Goals:**
- Automated build optimization (humans make investment decisions)
- Container orchestration or health checks beyond log visibility
- Metrics persistence or historical trending (one-shot analysis per build)
- Integration with external monitoring systems

## Decisions

### 1. Build Metrics Collection Strategy

**Decision**: Capture build phase timing and download sizes by parsing podman build output and injecting timing markers in Containerfile.

**Rationale**: 
- Parsing podman output avoids modifying container runtime
- Injecting RUN steps with `date +%s` captures phase boundaries
- Structured telemetry (JSON) makes analysis programmatic
- Alternative (cgroup memory/CPU monitoring) requires privileged access and complex systemd integration

**Implementation**:
- Add `struct BuildPhase { name: String, start_secs: u64, end_secs: u64, bytes_downloaded: u64 }` to ImageBuilder
- Inject markers in Containerfile at phase boundaries (after STEP 2 package install, STEP 17 agents, etc.)
- Parse podman build output for timing markers and download sizes (grep `Downloading`, `pulling`, `Installing`)
- Accumulate phases in a Vec, emit as JSON at build completion
- Emit as tracing event with spec: `build-metrics`, accountability: true

**Phases tracked**:
- Base system (STEP 1-17): OS packages, tools, agents
- Forge user & config (STEP 18-49): User setup, configs, overlays
- CLI tools (STEP 50-55): Discoverability CLIs
- Summarizers (STEP 56-66): Project analysis scripts
- Finalization (STEP 67-80): Symlinks, env vars, image commit

### 2. Optimization Suggestion Engine

**Decision**: Post-build analysis script that examines phase metrics and suggests cache/proxy optimizations.

**Rationale**:
- Decouples metrics collection from analysis logic
- Humans decide whether to invest in proxy cache, mirror pre-population, or layer reordering
- Avoids false positives from single-run variance

**Implementation**:
- After build_image() succeeds, call `analyze_build_metrics(&phases)` 
- Rules (configurable):
  - If package install > 45% of total time: suggest pre-populating `~/.cache/tillandsias/packages/`
  - If download_bytes > 1GB: suggest enabling host proxy cache (Squid tier)
  - If phase X is slowest: suggest reordering layers to fail early
- Emit as console message + log event with spec: `init-command`, suggestion_type: `<rule>`

### 3. Runtime Diagnostics Flag

**Decision**: New `--diagnostics` flag that spawns a parallel `tail -f` process for each running container.

**Rationale**:
- Avoids complex container orchestration (no health checks, liveness probes)
- Provides immediate visibility into container initialization
- Garbled output is acceptable (not for production dashboards, just dev troubleshooting)
- Simple to implement: for each container in project, spawn `podman run --rm -i <image> tail -f /strategic/service.log`

**Implementation**:
- Add `--diagnostics` flag to runner (CLI and tray app)
- On startup, discover all running containers for project (tag `tillandsias-<project>-*`)
- For each container:
  - Spawn async task: `podman exec <container_id> tail -f /strategic/service.log 2>/dev/null || echo "[<container> offline]"`
  - Prefix output with `[<service>] ` to disambiguate when garbled
  - Stream to stdout with no buffering
- Handles containers joining/leaving during run (periodic discovery)
- Ctrl+C stops all tails and exits cleanly

### 4. Log Location Convention

**Decision**: All containers write diagnostic logs to `/strategic/service.log`.

**Rationale**:
- Single well-known location per container
- Name suggests critical operational/startup diagnostics (not verbose debug logs)
- Prevents log flooding from debug/application logs

**Implementation**:
- Proxy container: create `/strategic/service.log`, write squid startup + requests
- Forge container: create `/strategic/service.log`, write entrypoint init + readiness
- Git service: create `/strategic/service.log`, write startup + push events
- Inference: create `/strategic/service.log`, write ollama health + model loading

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| Podman output parsing fragile across versions | Pin podman version in Containerfile; include fallback (missing metrics not fatal) |
| Build metrics noise from network variance | Run multiple builds and aggregate (future: collect over 3 runs, report median) |
| `/strategic/service.log` path assumes Linux container structure | OK for now; Windows containers defer (containers always run under Hyper-V) |
| `tail -f` with garbled output confusing to users | Document that `--diagnostics` is for development triage only; show [service-name] prefix |
| Log volumes from long-running stacks | Implement log rotation in containers (max 100MB per service log) |

## Migration Plan

1. Instrument ImageBuilder with phase timing (no externally visible change)
2. Collect metrics post-build, emit as structured log events
3. Add analysis rules for optimization suggestions
4. Implement `--diagnostics` flag in runner
5. Update telemetry documentation and observability guidelines
6. No breaking changes; all metrics/diagnostics optional (no config required)

## Open Questions

1. Should `--diagnostics` auto-tail from beginning or follow from now? (Proposal: follow from now, assume containers already starting)
2. Log rotation policy: max size vs. duration? (Proposal: 100MB max, override via TILLANDSIAS_LOG_SIZE env var)
3. Should metrics be persisted locally for multi-build trends? (Proposal: no, one-shot analysis only; future enhancement)
4. Should `--diagnostics` auto-exit when all containers stop, or wait indefinitely? (Proposal: wait indefinitely, user Ctrl+C)
