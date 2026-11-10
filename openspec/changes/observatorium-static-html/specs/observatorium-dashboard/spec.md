## ADDED Requirements

### Requirement: Static generated HTML presentation

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

## MODIFIED Requirements

### Requirement: Cloudflare deployment and local artifact

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

The headline residual SHALL use the latest valid measured release-cut snapshot
and name the release. The site SHALL show no current (deploy-time) collection.
Missing release evidence SHALL remain unavailable rather than borrowing a
current observation.

#### Scenario: Headline grade comes from the release cut

- **WHEN** the site is built from a checkout that ran no litmus
- **THEN** its headline residual names the latest measured release-cut snapshot
- **AND** no current observation appears anywhere on the site.

## REMOVED Requirements

### Requirement: Flutter and Flame presentation
**Reason**: operator ruling 2026-11-09: plain generated HTML replaces the Flutter app.
**Migration**: "Static generated HTML presentation"; the Flutter sources are deleted in PR 3 of 2066-obsv.

### Requirement: Managed forge build and browser loading
**Reason**: it describes the Flutter app (managed Flutter command, first Flutter frame, metrics fetch and retry); the static site has no build toolchain and fetches nothing at runtime.
**Migration**: "Static generated HTML presentation"; local preview is `node observatorium/site/build.mjs` and any static server.
