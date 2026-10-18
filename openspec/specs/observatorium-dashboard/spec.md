<!-- @trace spec:observatorium-dashboard -->
<!-- freshness: auditor=forge-observatorium date=2026-10-18 verdict=updated scope=inspectable obligation evidence and managed forge build -->

# Observatorium dashboard

## Status

active

## Purpose

Provide the operator-requested public metrics dashboard at
`observatorium.tillandsias.org`, implemented under `observatorium/`.
CentiColon convergence describes named, verifiable implementation obligations.
The legacy private trace viewer remains governed by `clickable-trace-index`.

## Requirements

### Requirement: Flutter and Flame presentation
<!-- req-id: 4f8d972b -->

The dashboard SHALL use Flutter for its web UI and Flame for charts. It SHALL
expose metric and time-window controls. Logarithmic plots SHALL name their
zero-safe transform and retain raw values and units.

#### Scenario: Different magnitudes

- WHEN a plot contains zero and measurements of widely different magnitudes
- THEN a zero-safe logarithmic transform allows them to share the plot
- AND displayed raw values retain the original measurement meaning.

### Requirement: Cheap collection and precomputed publication
<!-- req-id: 3c39b8b8 -->

Collection SHALL read existing sources and artifacts without executing the
measured project. Publication SHALL validate snapshots and precompute chart
coordinates. Rendering SHALL consume published JSON without GitHub or private
plan queries. Metrics SHOULD cover specs, folded plan states, residuals and
commits. Unavailable artifacts SHALL remain explained gaps.

#### Scenario: Missing residual artifact

- WHEN no supported residual obligation artifact is available
- THEN the metric is absent or null with a source availability explanation
- AND the dashboard does not imply there are zero remaining obligations.

### Requirement: Honest measurement history
<!-- req-id: af936098 -->

Every metric SHALL carry its definition, unit, source and measurement epoch.
Changed definitions SHALL start distinct epochs. Graphs SHALL preserve missing
intervals and SHALL NOT join epochs or reconstruct unobserved snapshots.
Historical commits MAY derive from real Git timestamps with coverage declared.
Snapshots SHALL carry source revision and observation time.

#### Scenario: Definition changes

- WHEN a metric changes how it counts its source
- THEN its new epoch begins at the first actual observation under that definition
- AND the previous epoch remains independently identifiable.

### Requirement: Inspectable implementation obligations
<!-- req-id: 1782be01 -->

The primary view SHALL show earned count, denominator, residual, evidence states
and residual reasons. Its unit SHALL remain the canonical grader's scenario
obligations, with the grade schema named, distinct from legacy weighted scores.
The current observation SHALL expose obligation IDs, requirement IDs, owning
specs and reasons. Activity and inventory counts SHALL NOT earn obligation credit.

#### Scenario: Current evidence is inspectable

- WHEN the grader emits declared, traced and positively tested obligations
- THEN the dashboard exposes their IDs, owning specs, states and reasons
- AND filtering by an ID or spec finds the corresponding obligations.

### Requirement: Validated grade provenance
<!-- req-id: 1782be02 -->

Release and current observations SHALL retain their own revision and time.
A release grade SHALL have nonnegative counts, earned plus residual equal to
denominator, consistent supplied evidence states and recorded results. A global
log count SHALL NOT imply matched evidence for each obligation. Malformed or
unmeasured grades SHALL remain explained gaps. Zero earned is valid.

#### Scenario: Release has no positively tested obligations

- WHEN a release records zero earned obligations and a nonzero denominator
- THEN the dashboard shows both numbers and residual reasons
- AND it does not infer positive coverage from unrelated historical log records.

#### Scenario: Invalid historical grade

- WHEN a release has an integer residual but inconsistent evidence counts
- THEN it is excluded from the headline and convergence series with a named gap
- AND a valid earlier release remains available.

### Requirement: Scope and simplification context
<!-- req-id: 1782be03 -->

Denominator changes SHALL be identified as scope changes rather than proof of
an implementation regression. A Lua migration inventory SHALL name its bounded
counting population and rules, remain separate from obligation credit, and SHALL
NOT imply that all remaining shell files contain substantive shell behavior.

#### Scenario: Source migration without behavioral evidence

- WHEN shell files are replaced by Lua scripts without new passing evidence
- THEN the inventory reflects the observed source change
- AND the dashboard does not increase earned obligations from those file counts.

### Requirement: Cloudflare deployment and local artifact
<!-- req-id: ecefcdde -->

Cloudflare Workers Builds SHALL deploy the app from root `observatorium` using
`npm run build` and `npx wrangler deploy`, static assets and the dashboard custom
domain. It SHALL use no GitHub Actions or Cloudflare credentials in GitHub.
The build SHALL pin downloaded toolchains by URL and SHA-256 and collect metrics
at deploy time, publishing unavailable metrics as gaps.

#### Scenario: Fresh deployment runner

- WHEN Workers Builds prepares a deployment from a fresh clone
- THEN the build produces the Flutter assets and precomputed metrics
- AND the app requires no private infrastructure at rendering time.

### Requirement: Durable release observations
<!-- req-id: 1782be04 -->

The release cut SHALL append exactly one snapshot naming its release tag to
`observatorium/history/snapshots.jsonl`, after a recorded litmus run with a
measured grade. Unmeasured grades SHALL be refused without appending. A deploy
SHALL read committed history without writing it; its live observation SHALL
remain display-only.

#### Scenario: Release cut records the release

- WHEN a release is cut
- THEN exactly one snapshot naming that tag is appended after recorded litmus
- AND an unmeasured grade is refused without changing history.

#### Scenario: Deployment cannot manufacture history

- WHEN a deployment reads committed release history
- THEN it may publish its current observation beside that history
- AND it never appends its live observation to the committed history.

### Requirement: Release and current evidence remain distinct
<!-- req-id: 1782be05 -->

The headline CentiColon grade SHALL use the latest valid measured release-cut
snapshot and name the release. Current collection SHALL remain labelled
display-only and SHALL NOT join the release series. Missing release evidence
SHALL remain unavailable rather than borrowing a current observation.

#### Scenario: Headline grade comes from the release cut

- WHEN the dashboard is deployed from a build that ran no litmus
- THEN its headline residual names the latest measured release-cut snapshot
- AND the current traced count appears in a separate display-only observation.

### Requirement: Managed forge build and browser loading
<!-- req-id: 1782be06 -->

Inside a forge, builds SHALL use the managed Flutter command and trusted sibling
toolchain. Standalone builds SHALL retain the pinned SDK path. Local publication
SHALL serve the selected app worktree's built assets. Browser loading SHALL use
web-compatible HTTP, expose retryable errors and retain the last snapshot on
refresh failure. Managed sibling and browser testing SHALL use host-browser when
available; absent infrastructure SHALL be reported as unverified.

#### Scenario: App loads in Chromium

- WHEN the built app is opened in the managed browser
- THEN it fetches published metrics and renders evidence
- AND the loading marker is removed after the first Flutter frame.

#### Scenario: Refresh fails after a successful load

- WHEN a subsequent metrics fetch fails
- THEN the last loaded snapshot and current controls remain available
- AND the failure is visible with a retry action.

## Authority and verification

Operator UX and Dart/Node authorization: `1661-vckd` (2026-10-13) and app repair
`1782-bek5` (2026-10-18). No tray UX changes are authorized.
Verification: Node collector/projection/build tests, Flutter analysis and widget
tests, release web build, managed sibling preview and Chromium interaction.
Public deployment requires separate live evidence; configuration is not proof.
