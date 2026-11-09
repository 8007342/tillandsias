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

A deploy build SHALL refuse unless the last release in
`history/snapshots.jsonl`, the newest `v*` tag reachable from HEAD, and HEAD's
`Observatorium-Release:` trailer all name the same release. A preview build
SHALL skip only the trailer check and SHALL say "preview build" on every page.

#### Scenario: Deploy commit without the trailer

- **WHEN** `node observatorium/site/build.mjs --deploy` runs on a commit with no `Observatorium-Release:` trailer
- **THEN** it prints `refused:missing-trailer` and exits non-zero.

## REMOVED Requirements

### Requirement: Flutter and Flame presentation
**Reason**: operator ruling 2026-11-09: plain generated HTML replaces the Flutter app.
**Migration**: "Static generated HTML presentation"; the Flutter sources are deleted in PR 3 of 2066-obsv.
