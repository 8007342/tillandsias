# Step 05: Observability, Logging, and Evidence Surfaces

## Status

completed (with documented gaps — see § Implementation Gaps below)

## Objective

Keep logs, diagnostics, traceability, and evidence bundles visible without reintroducing stale runtime assumptions.

## Included Specs

- `runtime-logging`
- `runtime-diagnostics`
- `runtime-diagnostics-stream`
- `external-logs-layer`
- `observability-convergence`
- `spec-traceability`
- `knowledge-source-of-truth`
- `clickable-trace-index`

## Deliverables

- A single, readable observability story.
- Spec-linked logs and traces that help the next hourly pass resume from the last meaningful failure boundary.
- Minimal spec churn around traceability and logging ownership.

## Verification

- Narrow observability litmus chain.
- `./build.sh --ci --strict --filter <observability-bundle>`
- `./build.sh --ci-full --install --strict --filter <observability-bundle>`

## Granular Tasks

- `observability/runtime-logging` — completed (commit `e653d3f3` marked completed; `crates/tillandsias-logging/` ships 15 passing unit tests; `litmus:runtime-logging-env-filter` bound)
- `observability/runtime-diagnostics` — completed (commit `e653d3f3` marked completed; `litmus:runtime-diagnostics-shape` + `litmus:external-logs-layer-shape` bound)
- `observability/diagnostics-stream` — completed (commit `a0c397c1` finalized Purpose section; `litmus:runtime-diagnostics-stream-shape`)
- `observability/trace-index` — completed (commit `a0c397c1` finalized; `scripts/generate-traces.sh` runs on every build; `TRACES.md` and per-spec `TRACES.md` files generated)
- `observability/source-of-truth` — completed (commit `a144e3a9` authored `knowledge-source-of-truth` spec with code > specs > cheatsheets > docs hierarchy, CRDT semantics, evidence-bundle structure)
- `observability/dashboard` — completed (commit `97dd30d2` added convergence dashboard; `scripts/update-convergence-dashboard.sh` renders `docs/convergence/centicolon-dashboard.{md,json}` from `target/convergence/centicolon-signature.jsonl`)

## Exit Criteria

- [x] Logs, traces, and diagnostics are observable without reintroducing stale assumptions.
- [x] `runtime-logging` spec defines log levels, destinations, file rotation (10 MB / 7-day TTL), and accountability windows (`--log-proxy`, `--log-enclave`, `--log-git`).
- [x] `runtime-diagnostics` spec defines exit codes, stderr capture, OOM detection, disk-full detection, fd-exhaustion detection, and pattern-matching (compilation / network / permission errors).
- [x] `runtime-diagnostics-stream` spec defines `--debug` activation, ISO 8601 timestamps, event types, backpressure (1000 events/sec rate limit, 10K ring buffer), and ephemeral lifecycle.
- [x] `clickable-trace-index` spec defines bidirectional spec↔code navigation; `TRACES.md` is regenerated on every build (POSIX-only, no external deps).
- [x] `knowledge-source-of-truth` spec authored with explicit authority hierarchy, CRDT-inspired monotonic convergence, spec-vs-code divergence resolution (code is wrong; spec wins), and evidence-bundle structure.
- [x] `observability-convergence` dashboard renders sparklines, latest signature, residual cc, and alert level from append-only signature log.
- [x] `external-logs-layer` defines INTERNAL vs EXTERNAL tier separation, producer manifest contract, parent-dir RO bind-mount, auditor invariants (manifest match, size cap, growth rate), and reverse-breach refusal.
- [ ] **Gap acknowledged**: log schema field-stability across releases is not enforced by a litmus test (see § Implementation Gaps).
- [ ] **Gap acknowledged**: convergence dashboard is rebuilt on demand, not in real time (see § Implementation Gaps).
- [ ] **Gap acknowledged**: external-logs-layer is specced and validated but not yet integrated with downstream consumers (e.g., Loki, Promtail, Vector); current integration is enclave-local only (see § Implementation Gaps).
- [ ] **Gap acknowledged**: resource metrics (CPU, memory, disk) are detected at exhaustion events but not continuously sampled into a metrics surface (see § Implementation Gaps).
- [ ] **Gap acknowledged**: trace coverage is bidirectional (TRACES.md exists) but coverage threshold (% of specs traced, % of @trace annotations resolving to live specs) is not enforced as a CI gate (see § Implementation Gaps).

## Implementation Gaps

This is the integrative "close the loop" review for Wave 10. Per the handoff guidance, **observability gaps remain graph-shaped, not linear guesswork** — each gap is modelled as a node in a dependency DAG so future agents can pick leaves without re-discovering blockers. Detailed gap audit lives in `plan/issues/observability-gaps-2026-05-14.md`.

### Gap graph (dependency-ordered, leaves first)

```
log-schema-stability (parent)
   ├── gap-log-field-name-stability-litmus           [LEAF]
   ├── gap-log-field-deprecation-tombstones          [LEAF]
   └── gap-log-schema-version-field                  [LEAF]

trace-coverage-completeness (parent)
   ├── gap-trace-coverage-threshold-ci-gate          [LEAF]
   ├── gap-dead-trace-detection-actionable           [LEAF]
   ├── gap-untraced-implementation-risk-surface      [LEAF]
   └── gap-trace-density-per-critical-path           [LEAF]

dashboard-freshness (parent)
   ├── gap-dashboard-realtime-vs-batch-update        [LEAF]
   ├── gap-dashboard-trend-window-configurability    [LEAF]
   └── gap-dashboard-alert-routing-external          [LEAF]

external-log-aggregation (parent)
   ├── gap-external-logs-loki-promtail-integration   [LEAF]
   ├── gap-external-logs-vector-sink-integration     [LEAF]
   └── gap-external-logs-schema-versioning           [LEAF]

resource-metric-collection (parent)
   ├── gap-continuous-cpu-metric-sampling            [LEAF]
   ├── gap-continuous-memory-metric-sampling         [LEAF]
   ├── gap-continuous-disk-io-metric-sampling        [LEAF]
   └── gap-cgroup-pressure-stall-info-collection     [LEAF]

evidence-bundle-discipline (parent)
   ├── gap-evidence-bundle-auto-generation-in-ci     [LEAF]
   ├── gap-evidence-bundle-signature-verification    [LEAF]
   └── gap-evidence-bundle-archival-retention        [LEAF]

observability-surface-completeness (parent)
   ├── gap-secret-rotation-event-coverage            [LEAF]
   ├── gap-image-build-event-coverage                [LEAF]
   ├── gap-cache-eviction-event-coverage             [LEAF]
   └── gap-network-policy-violation-event-coverage   [LEAF]
```

### High-level gap categories

1. **Log schema stability** — Log field names are *currently* stable (well-tested in `tillandsias-logging`) but their stability across releases is not enforced by a litmus test. A breaking rename (e.g., `container_exit_code` → `exit_code`) would silently break downstream log consumers (grep patterns, external aggregators). Need: a CI gate that diffs the log schema against a checked-in baseline.

2. **Trace coverage** — `TRACES.md` exists and `generate-traces.sh` runs on every build. But:
   - No CI gate enforces minimum coverage (e.g., "every active spec must have ≥1 trace").
   - Dead traces (annotations referencing a renamed/archived spec) appear as `(not found)` in TRACES.md but don't fail any check.
   - Untraced implementations (a Rust function implementing a spec without a `@trace` annotation) are invisible.

3. **Dashboard freshness** — `docs/convergence/centicolon-dashboard.{md,json}` are batch-rebuilt by `scripts/update-convergence-dashboard.sh`, typically after `./build.sh --ci-full`. There is no live/streaming update path; an in-progress build cannot watch the dashboard converge in real time.

4. **External log aggregation** — `external-logs-layer` is **specced and locally enforced** (producer manifest contract, auditor invariants, RO consumer mounts) but not integrated with downstream observability stacks (Loki/Promtail/Vector/Datadog/Honeycomb). The two-tier model is sound; the cross-host story is unfinished.

5. **Resource metric collection** — `runtime-diagnostics` detects resource *exhaustion* events (OOM kill, ENOSPC, EMFILE) but does not continuously sample CPU / memory / disk-IO. No cgroup pressure-stall-info (PSI) reading is performed. The dashboard reports residual cc but not resource saturation history.

6. **Evidence bundle discipline** — `knowledge-source-of-truth` defines the evidence-bundle structure (`target/convergence/evidence-bundle.json`). The generation, signing, and retention discipline around evidence bundles is documented but not automated:
   - Bundles aren't auto-produced by CI.
   - Bundles aren't signed (no `cosign` integration in the spec).
   - Bundles aren't archived (no retention policy).

7. **Observability surface completeness** — Several runtime behaviours emit log events but lack accountability tagging or `@trace` linkage:
   - Secret rotation events (rotating GitHub tokens, regenerating proxy CA).
   - Image build events (`scripts/build-image.sh forge` outputs are not in TRACES.md).
   - Cache eviction events (the dual-cache architecture in `forge-cache-dual` doesn't emit eviction telemetry).
   - Network policy violations (proxy denylist hits exist; enclave-network policy breaches don't have a dedicated event).

### Why these gaps remain open

The observability **foundation** is complete: structured logging, accountability windows, diagnostic capture, trace index, source-of-truth epistemology, and convergence dashboard. The above gaps are *extensions*: integration with external stacks, continuous metric collection, real-time dashboards, and automated evidence bundles.

The foundation is enough to:
- Debug a single forge session by `tail -f` of the relevant log.
- Validate spec convergence after a CI run.
- Trace any code path back to its governing spec.
- Detect container crashes, OOM, disk exhaustion.

The gaps are needed when:
- Multiple forge sessions run concurrently and need cross-session log aggregation.
- Resource saturation needs to be predicted, not just detected at exhaustion.
- Convergence needs continuous observation, not post-build snapshots.

None of these gaps block the current release. All are tracked in `plan/issues/observability-gaps-2026-05-14.md` for future waves.

## Handoff

- Assume the next agent may be different.
- Keep updates cold-start readable and idempotent: branch, file scope, checkpoint SHA, residual risk, dependency tail.
- **Cold-start note**: Observability implementation is complete; remaining work is gap closure. Pick leaves from the gap graph above rather than re-auditing the step. The detailed gap audit (`plan/issues/observability-gaps-2026-05-14.md`) carries severity, impact, fix paths, and spec references for every node. Per the handoff convention: *gaps remain graph-shaped, not linear guesswork* — preserve the DAG structure when adding new gaps.
