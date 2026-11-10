# Tasks — observatorium-static-html (2066-obsv)

## PR 1 — generator, Home, honesty rules
- [x] 1.1 Red-first tests for the honesty rules (site/honesty.test.mjs) and the deploy-trailer check (site/trailer.test.mjs), committed against permissive stubs (29/30 red).
- [x] 1.2 Derived view from history/snapshots.jsonl through metrics/evidence.mjs; nulls preserved; segments on epoch/denominator/scope change (site/view.mjs).
- [x] 1.3 Build-time SVG step chart and bar chart, each with a table twin (site/chart.mjs).
- [x] 1.4 Home page: stamp, two integers, reasons, residual over releases with breaks, goalposts ledger, standing disclaimer, plain reading (site/pages/home.mjs).
- [x] 1.5 Generator fails closed on a refused release or any lint violation (site/build.mjs).

## PR 2 — remaining pages
- [ ] 2.1 Releases index and per-release pages with the alignment panel.
- [ ] 2.2 Obligations: seven-rung histogram (four hatched "never produced"), table with JS filter; per-obligation pages when detail rows are retained.
- [ ] 2.3 Claims register from data/claims.yaml with strength categories.
- [ ] 2.4 Instrument, Glossary, Data pages.
- [ ] 2.5 Lint rule 3b: unproduced rungs always drawn hatched.

## PR 3 — deletions and manual deploy
- [ ] 3.1 Delete the Flutter app, legacy index.html, live metrics (collect/precompute), Containerfile and toolchain pins.
- [ ] 3.2 Delete docs/convergence/centicolon-dashboard.* and its generator.
- [ ] 3.3 Remove the automatic deploy/observatorium move from scripts/promote-stable.sh.
- [ ] 3.4 Fix methodology/versioning.yaml's "Workers Builds trigger" text.
- [ ] 3.5 wrangler.jsonc: no build command, assets from dist/, real 404; document the manual operator flow.
