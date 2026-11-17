<!-- @trace spec:observatorium-dashboard -->
<!-- freshness: auditor=yolanda date=2026-11-11 verdict=updated scope=observatorium-static-html archived (order 2066-obsv): static generated HTML, honesty lint, manual publish; Flutter and the managed forge build removed -->

# Observatorium dashboard

## Status

active

## Purpose

Provide the operator-requested public metrics dashboard at
`observatorium.tillandsias.org`, implemented under `observatorium/`.
CentiColon convergence describes named, verifiable implementation obligations.
The legacy private trace viewer remains governed by `clickable-trace-index`.

## Requirements

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

The observatorium SHALL be deployed only by the operator running
`wrangler deploy` by hand from a checkout of `refs/heads/deploy/observatorium`,
whose tree holds the built site and a `wrangler.jsonc` with no build command.
No Workers Builds trigger SHALL be connected to the Worker, nothing SHALL build
on Cloudflare, and no automation (release, promotion, hook, cron or CI) SHALL
write the deploy branch. It SHALL use no GitHub Actions and no Cloudflare
credentials in the repository. The build SHALL download nothing.

#### Scenario: Fresh deployment runner

- **WHEN** the operator deploys from a fresh checkout of `refs/heads/deploy/observatorium`
- **THEN** `npm run deploy` verifies the trailers and uploads the committed `dist/` with no build step
- **AND** the site requires no private infrastructure at rendering time.

#### Scenario: A stable promotion deploys nothing

- **WHEN** `scripts/promote-stable.sh` promotes a release
- **THEN** `refs/heads/deploy/observatorium` is unchanged
- **AND** no observatorium build or deploy starts.

### Requirement: Durable release observations
<!-- req-id: 1782be04 -->

The release cut SHALL append exactly one snapshot naming its release tag to
`observatorium/history/snapshots.jsonl`, after a recorded litmus run with a
measured grade. Unmeasured grades SHALL be refused without appending. Building
or deploying the site SHALL read committed history without writing it and
SHALL collect no live observation.

#### Scenario: Release cut records the release

- **WHEN** a release is cut
- **THEN** exactly one snapshot naming that tag is appended after recorded litmus
- **AND** an unmeasured grade is refused without changing history.

#### Scenario: Deployment cannot manufacture history

- **WHEN** the site is built for a deployment
- **THEN** every number it shows comes from committed release-cut snapshots
- **AND** nothing is appended to the committed history.

### Requirement: Release and current evidence remain distinct
<!-- req-id: 1782be05 -->

The headline residual SHALL use the latest valid measured release-cut snapshot
and name the release. The site SHALL show no current (deploy-time) collection.
Missing release evidence SHALL remain unavailable rather than borrowing a
current observation.

#### Scenario: Headline grade comes from the release cut

- **WHEN** the site is built from a checkout that ran no litmus
- **THEN** its headline residual names the latest measured release-cut snapshot
- **AND** no current observation appears anywhere on the site.

### Requirement: Static generated HTML presentation
<!-- req-id: 63f74e23 -->

The observatorium SHALL be plain multi-page HTML generated at build time from
the committed `observatorium/history/snapshots.jsonl` alone, with no network,
no toolchain download and no live metrics. Charts SHALL be inline SVG rendered
at build time, each with a `<table>` twin built from the same values. Pages
SHALL be complete without JavaScript; JavaScript MAY be used only to filter
tables. Markup SHALL be semantic and free of inline styles so it can be edited
in a visual editor.

#### Scenario: Built from committed history only

- **WHEN** `node observatorium/site/build.mjs` runs in a checkout with no network
- **THEN** it writes HTML, CSS, SVG and `data/history.json` derived only from `history/snapshots.jsonl`
- **AND** every chart in the output has a table twin.

### Requirement: Honesty lint fails the build closed
<!-- req-id: 2dac277d -->

Every number a generated page shows SHALL be bound to a field of the derived
view, and the build SHALL refuse to write any file when a page shows a number
that disagrees with the view, shows a value for a missing field (missing is
never 0), shows a ratio without its numerator and denominator and the words
"share of", uses a probability word, lacks an absolute release-and-UTC stamp,
uses a relative time, or joins a series across a scope, denominator or epoch
break. Published data SHALL contain no `host` key.

#### Scenario: A renderer maps null to zero

- **WHEN** a page shows `0` for a field the snapshot does not record
- **THEN** the build prints `refused:honesty-lint` with rule `missing-is-missing`
- **AND** no output file is written.

### Requirement: A stale snapshot cannot ship
<!-- req-id: 576ca4cd -->

A release build (`publish.mjs <tag>`) SHALL refuse unless the last release in
`history/snapshots.jsonl`, the newest `v*` tag reachable from HEAD, and the
named tag all agree, HEAD is that tag's commit and `observatorium/` is clean.
The commit it writes on `refs/heads/deploy/observatorium` SHALL carry
`Observatorium-Release`, `Observatorium-Snapshot` and `Observatorium-Source`
trailers, and `verify.mjs`, run before `wrangler deploy`, SHALL refuse unless
those trailers name the release and history digest the built data came from.
A preview build SHALL say "preview build" on every page.

#### Scenario: Deploy commit without the trailer

- **WHEN** `npm run deploy` runs on a deploy-branch commit with no `Observatorium-Release:` trailer
- **THEN** `verify.mjs` prints `refused:missing-trailer` and `wrangler deploy` does not run.

#### Scenario: Publishing an older release

- **WHEN** the deploy branch already serves a newer release
- **THEN** `publish.mjs` prints `refused:older-release` and writes nothing.

## Authority and verification

Operator UX and Dart/Node authorization: `1661-vckd` (2026-10-13) and app repair
`1782-bek5` (2026-10-18); static HTML rebuild and manual publishing by operator
ruling 2026-11-09 (order 2066-obsv, change archived as
`openspec/changes/archive/2026-11-11-observatorium-static-html`). No tray UX
changes are authorized.
Verification: `cd observatorium && npm test` (site generator, honesty lint,
publish and verify; gate step 930-2066-obsv), `litmus:stable-channel-shape`
(no automation writes the deploy ref) and
`scripts/test-promote-stable-evidence-gate.sh`.
Public deployment requires separate live evidence; configuration is not proof.
