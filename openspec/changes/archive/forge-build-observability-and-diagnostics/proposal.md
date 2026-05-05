## Why

Forge image builds take 2+ hours due to re-downloading ~6.5GB of packages on every build, with no visibility into which steps are slowest or largest. Developers can't identify optimization opportunities or diagnose failures in the build or runtime. Container health issues surface only after minutes of silent operation, requiring manual inspection.

## What Changes

- **Build Metrics**: Instrument `ImageBuilder::build_image()` to track download sizes, download times, and elapsed time for each major build phase (package install, tools, agents). Emit structured telemetry that identifies slowest/largest steps.
- **Cache Analysis**: Add analysis pass after build to suggest infrastructure optimizations (e.g., "package downloads account for 45% of build time — consider pre-populating mirror or using host proxy cache").
- **`--diagnostics` Runtime Flag**: New CLI flag that spawns all containers in a stack and streams their logs in parallel (`tail -f /strategic/service.log`) directly to the terminal. Provides real-time visibility of container initialization and health without requiring manual inspection or SSH.

## Capabilities

### New Capabilities
- `forge-build-metrics`: Track download sizes, times, and build phase durations; emit structured telemetry to identify optimization targets.
- `runtime-diagnostics`: Stream logs from all running containers in parallel for real-time visibility into stack health.

### Modified Capabilities
- `init-command`: Add metrics collection to forge image build; emit suggestions for cache/proxy optimization after build completes.
- `app-lifecycle`: Add `--diagnostics` flag to runtime launcher to enable multi-container log streaming.

## Impact

- **Code**: `src-tauri/src/image_builder.rs` (metrics), `src-tauri/src/init.rs` (analysis), `src-tauri/src/runner.rs` (diagnostics flag)
- **CLI**: New `--diagnostics` flag on tray launcher and CLI mode
- **Telemetry**: New log fields (`download_bytes`, `download_secs`, `phase_duration_secs`, `optimization_suggestion`)
- **UX**: Build output gains detailed metrics; diagnostics mode streams all container logs in real-time
