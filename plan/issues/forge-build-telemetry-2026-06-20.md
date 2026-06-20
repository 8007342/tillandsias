# Forge Build Telemetry — Install Times and Download Sizes

## Source

Drained from `plan.yaml` `future_intentions` item (post-item-3):
> "Add telemetry to measure install times and download sizes during forge build; save output in dev environment for analysis."

Trace: plan.yaml, plan/steps/58-future-intentions-drain.md

Status: claimed
Owner host: linux
Capability tags: [build, telemetry, containerfiles, shell]
Dependencies: none

events:
  - type: claim
    ts: "2026-06-20T17:00:00Z"
    agent_id: "linux-big-pickle-20260620T170000Z"
    host: linux
    lease_id: "forge-build-telemetry-20260620T170000Z"
    expires_at: "2026-06-20T21:00:00Z"
  - type: progress
    ts: "2026-06-20T17:10:00Z"
    agent_id: "linux-big-pickle-20260620T170000Z"
    note: >
      Slice 1 and 2 implemented: --progress json added to all 4 podman build paths;
      telemetry extraction function parses per-step timing, bytes_downloaded, and
      cache_hits from the JSONL progress log. Shell telemetry now also writes to the
      canonical ImageBuildEvent path ($XDG_STATE_HOME/tillandsias/image-build-events.jsonl)
      with schema_version=1 fields matching the Rust struct. Dashboard extended with
      download-size chart and latest-build summary table.
    evidence_refs:
      - "scripts/build-image.sh — --progress json on podman builds, _extract_build_telemetry, canonical ImageBuildEvent sink"
      - "scripts/generate-dashboard.sh — download-size Mermaid chart, latest build summary table"

## Current State

The forge build has **two independent telemetry backends** that are not converged:

### Shell path (`scripts/build-image.sh`)
- Measures **total** `duration_s` and `size_bytes` per image
- Records to `$HOME/.cache/tillandsias/telemetry/build-metrics.jsonl` (5-field JSONL: timestamp, image, duration_s, size_bytes, hash)
- Does NOT measure per-install-step durations, per-artifact download sizes, or individual RUN-layer cost

### Rust path (`tillandsias --init` via `crates/tillandsias-headless/src/main.rs`)
- Richer `ImageBuildEvent` schema with 20+ fields (schema_version, duration_ms, image_size_bytes, bytes_downloaded, cache_policy, etc.)
- Records to `$XDG_STATE_HOME/tillandsias/image-build-events.jsonl`
- Only used by the `--init` flow; shell workflow uses its own minimal format

### Existing hooks
- `build-image.sh` already saves full build log to `$ROOT/build-${IMAGE_NAME}.log`
- `build-image.sh` already computes source content hash and checks staleness
- Podman 5.8+ supports `--progress json` which emits per-step timing and download progress
- `scripts/generate-dashboard.sh` already exists but only consumes the minimal JSONL

## Gap Analysis

| Aspect | Status |
|---|---|
| Total build duration per image | ✅ captured |
| Final image size | ✅ captured |
| Per-RUN-layer duration | ❌ not captured |
| Per-artifact download size | ❌ not captured |
| Per-step podman cache decisions | ❌ not captured |
| Per-tool install time (dnf, npm, pip, curl, tar) | ❌ not captured |
| Total bytes downloaded per build | ❌ not captured |
| Unified telemetry schema (shell + Rust converge) | ❌ two separate sinks |
| Dev environment analysis dashboard | ⚠️ partial (`generate-dashboard.sh` exists, minimal) |
| Historical trend tracking | ❌ no retention/prometheus-style metrics |

## Proposed Instrumentation Plan

### Slice 1: Per-step timing via Podman JSON progress

Podman 5.8+ `--progress json` outputs structured build events including per-step:
- `step_duration_ms`
- `download_size_bytes` (for each pull/copy/download step)
- `cache_hit` / `cache_miss` per layer

Implementation:
1. Add `--progress json` flag to the `podman build` invocation in `scripts/build-image.sh`
2. Pipe the JSON progress output to a log file alongside the existing build log
3. Parse the JSON event stream after the build to extract:
   - Total wall-clock time per step
   - Download byte counts per artifact
   - Cache decision per layer
4. Append structured metrics to the telemetry JSONL

### Slice 2: Converge shell and Rust telemetry backends

1. Align the shell path's JSONL schema with `ImageBuildEvent` fields (add `duration_ms`, `bytes_downloaded`, `cache_result`, `decision`, `reason`)
2. Have both paths write to the same `image-build-events.jsonl` location (under `$XDG_STATE_HOME` where the Rust path already writes)
3. Cross-reference: add build-identity tag so shell-initiated and rust-initiated builds can be distinguished

### Slice 3: Dev environment analysis tooling

1. Extend `scripts/generate-dashboard.sh` to consume the richer JSONL schema
2. Produce a per-build summary table: total time, download size, cache-hit ratio, per-image breakdown
3. Add a CLI command (or script) to compare N most recent builds for regression detection
4. Save output to `$HOME/.cache/tillandsias/telemetry/` for operator review

## Architectural Note (for Tlatoani)

- The `--progress json` approach gives us all download-size data for free with zero Containerfile changes
- Per-install-step duration inside the container requires either: (a) wrapping each RUN in `time` and capturing to a build manifest file, or (b) using buildkit's `--output` mounts to write timing data out of the container
- Option (a) is simpler: wrap each heavy RUN layer in `time <command> && echo "<LABEL>: $SECONDS" >> /tmp/build-manifest`, then `podman run --rm <image> cat /tmp/build-manifest` to extract
- For initial implementation, Slice 1 (Podman JSON progress) covers 80% of the requirement with 10% of the effort
- The two-backend convergence (Slice 2) should happen before adding new dashboards (Slice 3) to avoid building on the wrong schema

## Acceptance Evidence

- `scripts/build-image.sh` emits per-step timing, download-size, and cache-hit metrics to telemetry JSONL ✅
  - `--progress json` added to all 4 podman build paths (base + main, verbose + non-verbose)
  - `_extract_build_telemetry` parses the JSONL progress log for step count, bytes_downloaded, cache_hits
- Metrics include: duration_s, size_bytes, bytes_downloaded, cache_hits, steps, decision, reason ✅
- `scripts/generate-dashboard.sh` renders duration, size, and download-size Mermaid charts + summary table ✅
- Shell path writes to canonical `$XDG_STATE_HOME/tillandsias/image-build-events.jsonl` with `ImageBuildEvent` schema (schema_version=1) — matching the Rust path's struct ✅
- Legacy metrics path `$HOME/.cache/tillandsias/telemetry/build-metrics.jsonl` preserved for backward compat ✅
- Backward-compat symlink: `build-*.log` → `build-*-progress.jsonl` for existing consumers ✅
- No regression in build speed or correctness; all existing E2E gates pass
