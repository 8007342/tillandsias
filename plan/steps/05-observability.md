# Step 05: Observability, Logging, and Evidence Surfaces

## Status

pending

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

- `observability/runtime-logging`
- `observability/diagnostics-stream`
- `observability/trace-index`
- `observability/knowledge-source`

## Handoff

- Assume the next agent may be different.
- Keep updates cold-start readable and idempotent: branch, file scope, checkpoint SHA, residual risk, dependency tail.
