## 1. Build Metrics Data Structure

- [ ] 1.1 Add `struct BuildPhase` to `src-tauri/src/image_builder.rs` with fields: name, start_secs, end_secs, bytes_downloaded
- [ ] 1.2 Add `Vec<BuildPhase>` field to `ImageBuilder` struct to accumulate phases during build
- [ ] 1.3 Add `fn parse_build_output_for_metrics()` helper to extract download sizes and timestamps from podman build output

## 2. Instrumentation of Containerfile

- [ ] 2.1 Identify major phase boundaries in Containerfile (packages, tools, agents, summarizers, finalization)
- [ ] 2.2 Inject `RUN echo "{timestamp}:{phase_name}:start" >&2` before each major phase
- [ ] 2.3 Inject `RUN echo "{timestamp}:{phase_name}:end" >&2` after each major phase
- [ ] 2.4 Ensure timing markers are captured in podman build output

## 3. Metrics Collection During Build

- [ ] 3.1 Modify `ImageBuilder::build_image()` to parse timing markers and download sizes from podman build output
- [ ] 3.2 Calculate phase duration_secs = end_timestamp - start_timestamp for each phase
- [ ] 3.3 Aggregate bytes_downloaded for each phase from grep of `Downloading`, `pulling`, `Installing` lines
- [ ] 3.4 Store phases in `self.build_phases` Vec at completion

## 4. Metrics Emission

- [ ] 4.1 After successful build, emit tracing event with spec="forge-build-metrics", phase_duration_secs, download_bytes
- [ ] 4.2 Format metrics as structured JSON for programmatic analysis
- [ ] 4.3 Include @trace spec:forge-build-metrics annotations in code

## 5. Optimization Suggestion Engine

- [ ] 5.1 Add `fn analyze_build_metrics(phases: &[BuildPhase]) -> Vec<Suggestion>` function to `init.rs`
- [ ] 5.2 Implement rule: if package_install > 45% of total → suggest pre-populating mirror or proxy cache
- [ ] 5.3 Implement rule: if total_bytes > 1GB → suggest enabling Squid proxy cache
- [ ] 5.4 Implement rule: identify slowest phase and suggest layer reordering
- [ ] 5.5 Call `analyze_build_metrics()` after build completion and print suggestions to stdout with emoji prefixes

## 6. Diagnostics Flag: Runner Integration

- [ ] 6.1 Add `--diagnostics` CLI flag to runner (CLI mode and tray app launcher)
- [ ] 6.2 Modify argument parsing in `src-tauri/src/runner.rs` to recognize `--diagnostics` flag
- [ ] 6.3 When flag is set, skip normal startup logic and enter diagnostics mode instead

## 7. Diagnostics Flag: Container Discovery

- [ ] 7.1 Implement `fn discover_running_containers(project: &str) -> Vec<ContainerInfo>` using podman API
- [ ] 7.2 Filter containers by tag pattern: `tillandsias-<project>-*`
- [ ] 7.3 Return ContainerInfo struct with container_id, service_name fields
- [ ] 7.4 Call discovery on startup and periodically (every 5 seconds) to detect new containers

## 8. Diagnostics Flag: Log Streaming

- [ ] 8.1 For each discovered container, spawn async task: `podman exec <container_id> tail -f /strategic/service.log 2>/dev/null`
- [ ] 8.2 Prefix output lines with `[<service_name>] ` for disambiguation
- [ ] 8.3 Handle offline containers: emit `[<service_name>] [offline]` and continue with other containers
- [ ] 8.4 Handle container exit: skip on next discovery cycle, don't error out
- [ ] 8.5 Clean termination: on Ctrl+C, kill all tail processes and exit with code 0

## 9. Proxy Container Logging

- [ ] 9.1 Create `/strategic/service.log` in proxy container entrypoint
- [ ] 9.2 Write squid startup status to log (timestamp, version, listening port)
- [ ] 9.3 Periodically log incoming request summary (requests/sec, total bytes proxied)
- [ ] 9.4 Implement log rotation: max 100MB, rotate to `.1`, discard older rotations

## 10. Forge Container Logging

- [ ] 10.1 Create `/strategic/service.log` in forge entrypoint
- [ ] 10.2 Log user setup completion and environment readiness indicators
- [ ] 10.3 Log when OpenCode/Claude/OpenSpec CLI tools are ready
- [ ] 10.4 Implement log rotation with TILLANDSIAS_LOG_SIZE environment variable support (default 100MB)

## 11. Git Service Container Logging

- [ ] 11.1 Create `/strategic/service.log` in git-service entrypoint
- [ ] 11.2 Log startup completion and git daemon listening status
- [ ] 11.3 Log authenticated push events (project, branch, committer)
- [ ] 11.4 Implement log rotation (max 100MB)

## 12. Inference Container Logging

- [ ] 12.1 Create `/strategic/service.log` in inference entrypoint
- [ ] 12.2 Log ollama startup and model loading progress
- [ ] 12.3 Log health check results (models loaded, VRAM available)
- [ ] 12.4 Implement log rotation (max 100MB)

## 13. Testing & Validation

- [ ] 13.1 Test build metrics collection with forge image build, verify phase aggregation
- [ ] 13.2 Test optimization suggestions: verify rules fire correctly for different phase ratios
- [ ] 13.3 Test `--diagnostics` flag with running stack, verify all logs stream correctly
- [ ] 13.4 Test offline container handling: stop a container during diagnostics, verify [offline] message
- [ ] 13.5 Test log rotation: write >100MB to strategic log, verify rotation occurs
- [ ] 13.6 Test environment variable override: set TILLANDSIAS_LOG_SIZE, verify custom limit applied

## 14. Documentation & Traces

- [ ] 14.1 Add @trace spec:forge-build-metrics annotations to metrics collection code
- [ ] 14.2 Add @trace spec:runtime-diagnostics annotations to diagnostics implementation
- [ ] 14.3 Add @trace spec:init-command annotations to metrics/analysis code in init.rs
- [ ] 14.4 Update CLI help text to document `--diagnostics` flag and purpose
- [ ] 14.5 Document `/strategic/service.log` convention in architecture guide
