<!-- @trace spec:observatorium-dashboard -->
<!-- freshness: auditor=forge-observatorium date=2026-10-13 verdict=updated scope=initial operator-authorized dashboard contract -->

# Observatorium dashboard

## Status

active

## Purpose

Provide the operator-requested public project metrics dashboard at
`observatorium.tillandsias.org`. Source, build tooling and deployment configuration
live under `observatorium/`; only CI wiring and canonical specification/plan
records live outside it. The legacy private trace viewer remains governed by
`clickable-trace-index` and does not become part of the public deployment.

## Requirements

### Requirement: Flutter and Flame presentation

The dashboard SHALL use Flutter for its web UI and Flame for chart rendering.
It SHALL expose controls for selecting metrics and time windows and render
precomputed logarithmic values with a clearly named transform. Zero SHALL remain
representable. Raw values and units SHALL remain available to interpret graphs.

#### Scenario: Different magnitudes

- WHEN a plot contains zero and measurements of widely different magnitudes
- THEN a zero-safe logarithmic transform allows them to share the plot
- AND displayed raw values retain the original measurement meaning.

### Requirement: Cheap collection and precomputed publication

Collection SHALL read existing project sources and artifacts without building or
executing the measured project. Deploy preparation SHALL validate snapshots and
precompute graph coordinates and summaries. Rendering SHALL consume the published
JSON artifact without querying GitHub or the private plan infrastructure.
The initial metrics SHOULD cover specs, effective plan states, residual obligation
artifacts where available, and commits. Missing artifacts SHALL be represented as
unavailable rather than a zero measurement.

#### Scenario: Missing residual artifact

- WHEN no supported residual obligation artifact is available
- THEN the metric is absent or null with a source availability explanation
- AND the dashboard does not imply that there are zero remaining obligations.

### Requirement: Honest measurement history

Every metric SHALL carry its definition, unit, source and measurement epoch.
Changed definitions SHALL start a distinct epoch. Graphs SHALL preserve missing
intervals and SHALL NOT join epochs or reconstruct unobserved historical snapshot
counts. Historical commits MAY be derived from real Git timestamps, with history
coverage declared. Snapshots SHALL carry a source revision and observation time.

#### Scenario: Definition changes

- WHEN a metric changes how it counts its source
- THEN its new epoch begins at the first actual observation under that definition
- AND the previous epoch remains independently identifiable.

### Requirement: Cloudflare deployment and local artifact

The app SHALL support `npx wrangler deploy` from `observatorium/` after preparation,
using Cloudflare static assets and a custom domain for the dashboard subdomain.
CI SHALL prepare and deploy on pushes to main and published releases, with
credentials supplied through repository secrets. Deployment history SHALL be
restored from durable storage and updated after successful publication rather
than silently resetting on every ephemeral runner. Local artifact serving SHALL
use the same built assets. Managed sibling publication and device dogfooding SHALL
use host-browser tools when available; their absence SHALL be documented as an
unverified infrastructure dependency.

#### Scenario: Fresh deployment runner

- WHEN a new runner prepares a deployment
- THEN it restores previously published snapshots before adding its observation
- AND a missing or inaccessible prior history cannot silently replace known history.

## Authority and verification

Operator UX and Dart/Node wrapper authorization: plan packet `1661-vckd`,
2026-10-13. No tray UX changes are authorized by this spec.
Verification: collector and preparation tests under `observatorium/metrics/`,
Flutter analysis/widget tests and release web build, Wrangler deployment dry run,
and local artifact response checks. Public deployment and managed device testing
require live credentials and host services; configuration alone is not evidence
that either ran.
