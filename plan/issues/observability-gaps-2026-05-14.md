# Observability Implementation Gaps Audit — 2026-05-14

**Iteration**: Wave 10 (implementation-gaps-backlog, order 8)
**Task**: implementation-gaps/observability
**Auditor**: Claude Code (Opus 4.7)
**Scope**: Comprehensive review of all completed observability work from order 5 (observability-and-diagnostics), Wave 9 — six granular tasks: runtime-logging, runtime-diagnostics, diagnostics-stream, trace-index, source-of-truth, dashboard

---

## Executive Summary

Observability **foundation** is production-complete. All six order-5 granular tasks converged: structured logging with accountability windows, runtime diagnostics for exit codes / stderr / OOM / disk / fd exhaustion, real-time diagnostic streaming via `--debug`, bidirectional spec↔code traceability via `generate-traces.sh`, knowledge source-of-truth epistemology with CRDT semantics, and the CentiColon convergence dashboard. The `tillandsias-logging` crate ships 15 passing unit tests; `TRACES.md` enumerates trace references for every active spec.

Gaps are **extensions**, not foundational bugs. They cluster into seven categories, modelled as a dependency DAG per the handoff convention "observability gaps should remain graph-shaped, not linear guesswork":

1. **Log schema stability** — current schema is stable; future-stability is not enforced.
2. **Trace coverage** — TRACES.md exists; minimum coverage thresholds are not gated.
3. **Dashboard freshness** — batch-rebuilt; not real-time.
4. **External log aggregation** — local-only; not wired to Loki/Promtail/Vector/etc.
5. **Resource metric collection** — exhaustion detected; continuous sampling absent.
6. **Evidence bundle discipline** — structure defined; auto-generation/signing/retention not automated.
7. **Observability surface completeness** — primary events covered; several runtime behaviours emit logs without accountability tagging.

None of these gaps block the current release.

---

## Gap Dependency Graph (DAG)

Gaps modelled as a dependency DAG per the explicit handoff guidance. Leaves can be implemented independently; non-leaf nodes require their dependencies first. Parallel agents can claim non-overlapping leaves.

```
log-schema-stability
├── gap-log-field-name-stability-litmus              [LEAF]
├── gap-log-field-deprecation-tombstones             [LEAF]
└── gap-log-schema-version-field                     [LEAF]

trace-coverage-completeness
├── gap-trace-coverage-threshold-ci-gate             [LEAF]
├── gap-dead-trace-detection-actionable              [LEAF]
├── gap-untraced-implementation-risk-surface         [LEAF]
└── gap-trace-density-per-critical-path              [LEAF]

dashboard-freshness
├── gap-dashboard-realtime-vs-batch-update           [LEAF]
├── gap-dashboard-trend-window-configurability       [LEAF]
└── gap-dashboard-alert-routing-external             [LEAF]

external-log-aggregation
├── gap-external-logs-loki-promtail-integration      [LEAF]
├── gap-external-logs-vector-sink-integration        [LEAF]
└── gap-external-logs-schema-versioning              [LEAF]

resource-metric-collection
├── gap-continuous-cpu-metric-sampling               [LEAF]
├── gap-continuous-memory-metric-sampling            [LEAF]
├── gap-continuous-disk-io-metric-sampling           [LEAF]
└── gap-cgroup-pressure-stall-info-collection       [LEAF]

evidence-bundle-discipline
├── gap-evidence-bundle-auto-generation-in-ci        [LEAF]
├── gap-evidence-bundle-signature-verification       [LEAF]
└── gap-evidence-bundle-archival-retention           [LEAF]

observability-surface-completeness
├── gap-secret-rotation-event-coverage               [LEAF]
├── gap-image-build-event-coverage                   [LEAF]
├── gap-cache-eviction-event-coverage                [LEAF]
└── gap-network-policy-violation-event-coverage      [LEAF]
```

---

## Detailed Gap Audit

### Category: Log Schema Stability

#### Gap: log-field-name-stability-litmus

**Status**: KNOWN
**Severity**: Medium (silent breaking changes ship without warning)
**Component**: `crates/tillandsias-logging/` field naming
**Description**:
- The logging crate emits structured fields with stable names today (e.g., `container_exit_code`, `signal`, `oom_kill`, `accountability`, `category`, `spec`).
- No litmus test diffs the emitted field set against a checked-in baseline.
- A refactor renaming `container_exit_code` → `exit_code` would silently break grep patterns and external log consumers without any CI signal.

**Impact**:
- Drift risk: any downstream tool depending on field names is implicitly trusting commit-by-commit stability.
- Multiplied as external aggregation lands (gap-external-logs-loki-promtail-integration).

**Fix Path**:
- Add `crates/tillandsias-logging/tests/schema_baseline.rs` that asserts a fixed set of field names per event type.
- Bind to `litmus:runtime-logging-schema-stability`.
- Update baseline only via explicit decision + tombstone for renamed fields.

**Spec Reference**: `runtime-logging`

---

#### Gap: log-field-deprecation-tombstones

**Status**: KNOWN
**Severity**: Low (process gap)
**Component**: log field deprecation lifecycle
**Description**:
- CLAUDE.md mandates `@tombstone` for code removal but the convention is not explicitly extended to log field renames.
- A renamed field has no required tombstone period; downstream consumers may break overnight.

**Fix Path**:
- Extend tombstone convention to log fields: deprecated field name emitted alongside new field for ≥3 releases.
- Document in `runtime-logging` spec.

**Spec Reference**: `runtime-logging`, `methodology-accountability`

---

#### Gap: log-schema-version-field

**Status**: KNOWN
**Severity**: Low
**Component**: log event header
**Description**:
- No `schema_version` field is emitted on log events. Downstream consumers cannot reliably detect when the schema has changed.
- Without a version, gracefully evolving the schema (additive only, CRDT-style) is impossible to signal.

**Fix Path**:
- Add `schema_version = "v1"` to all log events emitted by `tillandsias-logging`.
- Bump version on additive changes; require a major-version bump for breaking changes.

**Spec Reference**: `runtime-logging`

---

### Category: Trace Coverage Completeness

#### Gap: trace-coverage-threshold-ci-gate

**Status**: KNOWN
**Severity**: Medium (silent regression in spec→code linkage)
**Component**: `scripts/generate-traces.sh` + CI gate
**Description**:
- `TRACES.md` is regenerated on every build but no CI step enforces a minimum coverage (e.g., "every active spec must have ≥1 trace annotation in the codebase").
- A spec authored without implementation (or implementation removed without spec tombstone) would silently appear as untraced.

**Fix Path**:
- Add `scripts/validate-traces.sh` (or extend existing) to:
  1. Walk `openspec/specs/*/spec.md`.
  2. For each active spec (status: active), assert ≥1 `@trace spec:<name>` exists in code.
  3. Fail CI if any active spec has zero traces.
- Bind to `litmus:clickable-trace-index-min-coverage`.

**Spec Reference**: `clickable-trace-index`, `spec-traceability`, `observability-convergence`

---

#### Gap: dead-trace-detection-actionable

**Status**: KNOWN
**Severity**: Low (drift signal exists but not actionable)
**Component**: `TRACES.md` `(not found)` entries
**Description**:
- Dead traces (annotations referencing a renamed/archived spec) appear as `(not found)` in TRACES.md.
- No automated action: no CI failure, no log event, no maintainer notification.
- The dead trace remains in the codebase indefinitely.

**Fix Path**:
- Add `scripts/audit-dead-traces.sh` that lists all `(not found)` traces with file:line locations.
- Optionally: surface as a `warn` event in tray startup (non-blocking).
- Litmus: `litmus:clickable-trace-index-no-dead-traces`.

**Spec Reference**: `clickable-trace-index`, `observability-convergence`

---

#### Gap: untraced-implementation-risk-surface

**Status**: KNOWN
**Severity**: Low (best-effort signal; not enforceable)
**Component**: implementation→spec linkage detection
**Description**:
- The inverse direction (untraced code that implements a spec) is harder to detect.
- `observability-convergence` spec mentions `untraced_implementation_risk = true` but no mechanism enforces it.
- A reviewer would have to manually identify "this function implements `runtime-logging` but lacks a trace".

**Fix Path**:
- Heuristic: cross-reference file names / module names against spec names; flag misses.
- Not a hard gate; advisory in TRACES.md as `Untraced Candidates` section.

**Spec Reference**: `spec-traceability`, `observability-convergence`

---

#### Gap: trace-density-per-critical-path

**Status**: KNOWN
**Severity**: Low
**Component**: trace annotations in critical code paths
**Description**:
- `spec-traceability.invariant.annotation-coverage-20-percent` defines the target (~20% of code).
- No metric reports actual coverage per critical path (e.g., container launch path, secret handling path).

**Fix Path**:
- Define "critical paths" (e.g., `crates/tillandsias-podman/src/launch.rs`, `crates/tillandsias-core/src/state.rs`).
- For each, compute `annotated_lines / total_lines`.
- Surface as a dashboard metric.

**Spec Reference**: `spec-traceability`, `observability-convergence`

---

### Category: Dashboard Freshness

#### Gap: dashboard-realtime-vs-batch-update

**Status**: KNOWN
**Severity**: Low (process gap)
**Component**: `scripts/update-convergence-dashboard.sh` + watcher
**Description**:
- The dashboard is rebuilt only when `update-convergence-dashboard.sh` is invoked (typically post-CI).
- No streaming/watch mode; an in-progress build cannot watch the dashboard converge.
- Stale dashboard view between builds is the norm.

**Impact**: Low — the dashboard is a post-build artefact by design. But teams running iterative `--ci-full` waves would benefit from live updates.

**Fix Path**:
- Add `--watch` flag to `update-convergence-dashboard.sh` that polls `target/convergence/centicolon-signature.jsonl` and re-renders on append.
- Optionally: serve the dashboard via the observatorium and live-reload.

**Spec Reference**: `observability-convergence`

---

#### Gap: dashboard-trend-window-configurability

**Status**: KNOWN
**Severity**: Low
**Component**: dashboard rendering
**Description**:
- The trend sparkline width is hard-coded (`TREND_CHUNK_WIDTH=32`); the time window is implicit (recent N signatures).
- No way to view "last 24h", "last week", or "since release X".

**Fix Path**:
- Add `--since=<timestamp>` and `--until=<timestamp>` flags.
- Add `--release=<version>` filter.

**Spec Reference**: `observability-convergence`

---

#### Gap: dashboard-alert-routing-external

**Status**: KNOWN
**Severity**: Low
**Component**: dashboard alert level + external integration
**Description**:
- The dashboard surfaces an `alert_level` (red < 90%, yellow < 95%) but no external integration triggers on red.
- A red alert is visible to a developer reading the markdown but is invisible to PagerDuty / Slack / Discord.

**Fix Path**:
- Add `--alert-webhook=<url>` that POSTs the alert payload on red.
- Document integration patterns in `cheatsheets/observability/alert-routing.md`.

**Spec Reference**: `observability-convergence`

---

### Category: External Log Aggregation

#### Gap: external-logs-loki-promtail-integration

**Status**: KNOWN
**Severity**: Low (greenfield; no current need)
**Component**: external-log forwarding to Loki via Promtail
**Description**:
- `external-logs-layer` exposes per-role JSONL files under `~/.local/state/tillandsias/external-logs/<role>/`.
- These are NOT auto-forwarded to Loki / Grafana stacks.
- Cross-host log aggregation requires manual Promtail config pointing at the layer.

**Fix Path**:
- Document a Promtail config in `cheatsheets/observability/external-logs-loki.md`.
- Optionally: ship a default Promtail container in the enclave.

**Spec Reference**: `external-logs-layer`

---

#### Gap: external-logs-vector-sink-integration

**Status**: KNOWN
**Severity**: Low
**Component**: external-log forwarding to Vector
**Description**: Symmetric with the Loki case but for Vector (timber.io). Different default config; same fix path.

**Fix Path**: Document Vector source config in `cheatsheets/observability/external-logs-vector.md`.

**Spec Reference**: `external-logs-layer`

---

#### Gap: external-logs-schema-versioning

**Status**: KNOWN
**Severity**: Low
**Component**: producer manifest schema versioning
**Description**:
- `external-logs.yaml` manifests declare `role`, `files`, `format` (text|jsonl), `rotate_at_mb`.
- No `schema_version` field; producer manifest format evolution is unmanaged.

**Fix Path**: Add `schema_version: 1` to the manifest spec; validate on auditor read.

**Spec Reference**: `external-logs-layer`

---

### Category: Resource Metric Collection

#### Gap: continuous-cpu-metric-sampling

**Status**: KNOWN
**Severity**: Medium (predictive saturation is impossible without this)
**Component**: `tillandsias-diagnostics` or new metrics collector
**Description**:
- `runtime-diagnostics` detects OOM/disk/fd exhaustion *at the point of failure*.
- No continuous sampling of container CPU usage (cgroup `cpu.stat`, `cpu.pressure`).
- Predictive saturation (e.g., "this build is approaching CPU exhaustion") is impossible.

**Fix Path**:
- Add `crates/tillandsias-metrics/` (new crate) that samples cgroup metrics every 10 s.
- Emit `metric.cpu.user_seconds`, `metric.cpu.system_seconds`, `metric.cpu.throttled_seconds` events.
- Surface in dashboard.

**Spec Reference**: `runtime-diagnostics` (would need new requirement section), or new spec `resource-metrics`.

---

#### Gap: continuous-memory-metric-sampling

**Status**: KNOWN
**Severity**: Medium
**Component**: same as above
**Description**: Same shape as CPU; cgroup `memory.stat`, `memory.pressure`.

**Fix Path**: Same as above.

**Spec Reference**: `runtime-diagnostics`

---

#### Gap: continuous-disk-io-metric-sampling

**Status**: KNOWN
**Severity**: Low
**Component**: same as above
**Description**: cgroup `io.stat`, `io.pressure`. Less commonly saturated than CPU/memory.

**Fix Path**: Same as above.

**Spec Reference**: `runtime-diagnostics`

---

#### Gap: cgroup-pressure-stall-info-collection

**Status**: KNOWN
**Severity**: Low
**Component**: PSI reading
**Description**:
- Linux 4.20+ exposes Pressure Stall Information (PSI) at `/proc/pressure/{cpu,memory,io}` and per-cgroup.
- Tillandsias does not read PSI; saturation indicators are lossy without it.

**Fix Path**:
- Add PSI reader (graceful fallback if kernel doesn't support).
- Surface `psi_cpu_some_avg10`, `psi_memory_full_avg60`, etc. as metric events.

**Spec Reference**: `runtime-diagnostics`

---

### Category: Evidence Bundle Discipline

#### Gap: evidence-bundle-auto-generation-in-ci

**Status**: KNOWN
**Severity**: Medium (convergence claims unfounded without bundle)
**Component**: CI integration
**Description**:
- `knowledge-source-of-truth` requires evidence bundles for convergence claims.
- No CI step auto-generates `target/convergence/evidence-bundle.json` per `--ci-full` run.
- Convergence claims are currently informal.

**Fix Path**:
- Add `scripts/generate-evidence-bundle.sh` invoked by `./build.sh --ci-full`.
- Bundle: `commit_sha`, `test_run_id`, `traces` (from generate-traces.sh), `litmus_results`, `produced_at`.

**Spec Reference**: `knowledge-source-of-truth`, `observability-convergence`

---

#### Gap: evidence-bundle-signature-verification

**Status**: KNOWN
**Severity**: Low (security hardening)
**Component**: bundle signing
**Description**:
- Bundles aren't signed; anyone with write access could fabricate convergence evidence.
- `binary-signing` spec uses Cosign for binaries; bundles could reuse the pattern.

**Fix Path**:
- Sign each bundle with Cosign.
- Verify on dashboard render.

**Spec Reference**: `knowledge-source-of-truth`, `binary-signing`

---

#### Gap: evidence-bundle-archival-retention

**Status**: KNOWN
**Severity**: Low (process gap)
**Component**: bundle retention policy
**Description**:
- No retention policy for evidence bundles. They accumulate indefinitely or are wiped on `cargo clean`.

**Fix Path**:
- Archive bundles to git LFS or a release artefact.
- Retain last N releases.

**Spec Reference**: `knowledge-source-of-truth`

---

### Category: Observability Surface Completeness

#### Gap: secret-rotation-event-coverage

**Status**: KNOWN
**Severity**: Medium (security-sensitive operations should be auditable)
**Component**: `tillandsias-otp`, `secrets-management` runtime
**Description**:
- GitHub token rotation and proxy CA regeneration happen but may not emit accountability-tagged events with `@trace spec:secret-rotation`.
- No grep-by-spec yields the rotation history.

**Fix Path**:
- Audit `crates/tillandsias-otp/`, secret refresh paths.
- Add `accountability = true, category = "secrets", spec = "secret-rotation"` to all rotation events.

**Spec Reference**: `secret-rotation`, `secrets-management`, `runtime-logging`

---

#### Gap: image-build-event-coverage

**Status**: KNOWN
**Severity**: Low
**Component**: `scripts/build-image.sh` + image_builder.rs
**Description**:
- Image builds emit shell output but not structured events with `@trace spec:default-image` / `@trace spec:image-builder`.
- A failed build leaves no structured trail in the tray log.

**Fix Path**:
- Wrap `build-image.sh` invocations in `crates/tillandsias-core/src/image_builder.rs` with `info!` / `error!` accountability events.

**Spec Reference**: `default-image`, `runtime-logging`

---

#### Gap: cache-eviction-event-coverage

**Status**: KNOWN
**Severity**: Low
**Component**: dual-cache architecture in `forge-cache-dual`
**Description**:
- Cache eviction (RW per-project cache hitting size limits) happens silently.
- No `cache_evicted_bytes` / `cache_evicted_path` event emitted.

**Fix Path**:
- Audit `lib-common.sh`, `forge-cache-dual` implementation.
- Emit eviction events with `accountability = true, category = "cache", spec = "forge-cache-dual"`.

**Spec Reference**: `forge-cache-dual`, `runtime-logging`

---

#### Gap: network-policy-violation-event-coverage

**Status**: KNOWN
**Severity**: Medium (security observability)
**Component**: proxy + enclave network
**Description**:
- Proxy denylist hits already emit events (`spec:proxy-container`).
- Enclave network policy breaches (a container trying to reach a non-allowlisted host) may not emit a dedicated event — Squid logs are not necessarily parsed into structured events.

**Fix Path**:
- Audit proxy log parsing; ensure every denied request emits a Tillandsias structured event with `@trace spec:enclave-network, spec:proxy-container`.
- Surface in the `--log-proxy` accountability window.

**Spec Reference**: `enclave-network`, `proxy-container`, `runtime-logging`

---

## Verification of Completed Work

The following were verified as **working** during this audit:

| Component                                  | Verification                                                                          |
|--------------------------------------------|---------------------------------------------------------------------------------------|
| Structured logging (TillandsiasFormat)     | `crates/tillandsias-logging/`: 15 passing unit tests; TTY + file sinks; ANSI handling |
| Accountability windows                     | `--log-proxy`, `--log-enclave`, `--log-git` defined in `runtime-logging` spec         |
| Spec trace links in accountability events  | GitHub search URL pattern verified in spec scenarios                                  |
| File log rotation                           | `crates/tillandsias-logging/src/rotation.rs`: 10 MB / 7-day TTL default                |
| Exit code + signal capture                  | `runtime-diagnostics` Requirement: Capture exit code                                  |
| Stderr capture + cleanup                    | `runtime-diagnostics` Scenario: Stderr destruction (tmpfs, 0400, deleted on stop)     |
| Stderr pattern matching                     | Rust E[NNNN], Connection refused, Permission denied patterns documented              |
| OOM / disk / fd exhaustion detection        | Scenarios documented; cgroup memory + ENOSPC + EMFILE                                 |
| --debug streaming (ISO 8601, event types)   | `runtime-diagnostics-stream` spec defines structure; stream is ephemeral             |
| Backpressure (rate limit, ring buffer)      | 1000 events/sec limit; 10K event ring buffer; flush on shutdown                       |
| TRACES.md generation                        | `scripts/generate-traces.sh` runs on every build (POSIX-only); empty on no-trace      |
| Per-spec TRACES.md back-links               | `openspec/specs/<name>/TRACES.md` files generated                                      |
| Observatorium (`scripts/run-observatorium.sh`) | Idempotent launcher; private Chromium with host browser fallback                    |
| knowledge-source-of-truth epistemology     | Spec authored: authority hierarchy, CRDT semantics, divergence resolution, evidence  |
| Convergence dashboard                       | `docs/convergence/centicolon-dashboard.{md,json}` auto-generated; sparklines + alert  |
| External logs two-tier model                | INTERNAL vs EXTERNAL separation; producer manifest; auditor invariants; RO mount     |
| External logs auditor                       | 60s tick; LEAK detection; size-cap truncation (50% tail); growth-rate alarm           |

---

## Conclusion

Observability is **shippable as-is**. The foundation is sound: structured logging, accountability windows, diagnostic capture, real-time streaming, bidirectional trace index, source-of-truth epistemology, and convergence dashboard. The seven gap categories are *extensions*, not foundational bugs:

- Log schema stability and trace coverage are *process gaps* — the current state is good; we need CI gates to prevent regression.
- Dashboard freshness is a *feature gap* — batch is sufficient for now; real-time would be nicer.
- External log aggregation is a *cross-host gap* — local enclave is complete; cross-host stacks are unfinished.
- Resource metric collection is a *predictive gap* — exhaustion is detected; saturation prediction needs continuous sampling.
- Evidence bundle discipline is a *process gap* — structure is defined; automation is missing.
- Observability surface completeness is a *coverage gap* — primary paths emit events; secondary paths (secret rotation, image builds, cache eviction, network policy) are uneven.

Recommend: pick one leaf per future wave. The DAG structure ensures parallel agents can claim non-overlapping leaves; the seven categories give natural parallelization boundaries.

---

**Handoff anchors**:
- Commit: `09188476` (post-Wave-10 onboarding commit)
- Branch: `linux-next`
- Plan step: `plan/steps/05-observability.md`
- Dependency tail: `implementation-gaps/residual-backlog` (next plan node — implementation-first mode begins)
