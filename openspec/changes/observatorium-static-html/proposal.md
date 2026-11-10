# Proposal — observatorium-static-html

Order: `2066-obsv`. @trace spec:observatorium-dashboard

## Why

The blind design exercise (`plan/issues/observatorium-blind-design-2026-11-09/`)
scored the existing Flutter observatorium 38/86 against 65/86 for a static
design. The existing app needs Flutter, rustup and live metrics at deploy
time, renders to a canvas with no table fallback, and is wired to a Cloudflare
Workers Builds trigger. A second, stale dashboard
(`docs/convergence/centicolon-dashboard.*`, 89.9% closed, 2026-08-09)
contradicts it.

Operator rulings, 2026-11-09 (packet README): plain generated HTML replaces the
Flutter app and will be used to test the GrapesJS local editor; the legacy
dashboard is deleted; there is NO auto-deploy anywhere, publishing is a manual
`wrangler deploy` from the operator's machine after a release, and no Workers
Builds trigger is ever connected.

## What changes

- `observatorium/site/`: a Node generator with no dependencies and no network
  that reads only the committed `history/snapshots.jsonl`, validates every row
  with the existing `metrics/evidence.mjs`, and writes plain multi-page HTML
  with build-time SVG charts, each with a `<table>` twin. JS only for table
  filtering.
- Honesty rules (design.md §3) run as a lint over every generated file, and the
  build writes nothing if any rule fails: missing is missing (never 0), two
  integers before any ratio, no probability words, an absolute stamp on every
  page, no series joined across a break, no `host` key in published data.
- A stale snapshot cannot ship: a `--deploy` build requires the history's last
  release, the newest reachable `v*` tag and HEAD's
  `Observatorium-Release:` trailer to agree.
- Pages: Home, Releases, Obligations, Claims, Instrument, Glossary, Data.
- Removed: the Flutter app and its toolchain pins, the legacy Chart.js
  `index.html`, live deploy-time metrics, `docs/convergence/centicolon-dashboard.*`,
  and the automatic `deploy/observatorium` move in `scripts/promote-stable.sh`.
  `methodology/versioning.yaml` stops claiming a Workers Builds trigger.

## Delivery

Three PRs from `work/2066-obsv`: (1) generator, Home, honesty rules, trailer
check; (2) the remaining pages; (3) deletions and the manual deploy flow.
