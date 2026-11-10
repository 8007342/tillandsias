# Tasks — observatorium-static-html (2066-obsv)

## PR 1 — generator, Home, honesty rules
- [x] 1.1 Red-first tests for the honesty rules (site/honesty.test.mjs) and the deploy-trailer check (site/trailer.test.mjs), committed against permissive stubs (29/30 red).
- [x] 1.2 Derived view from history/snapshots.jsonl through metrics/evidence.mjs; nulls preserved; segments on epoch/denominator/scope change (site/view.mjs).
- [x] 1.3 Build-time SVG step chart and bar chart, each with a table twin (site/chart.mjs).
- [x] 1.4 Home page: stamp, two integers, reasons, residual over releases with breaks, goalposts ledger, standing disclaimer, plain reading (site/pages/home.mjs).
- [x] 1.5 Generator fails closed on a refused release or any lint violation (site/build.mjs).

## PR 2 — remaining pages
- [x] 2.1 Releases index (JS filter, progressive) and per-release pages with the alignment panel; alignment says "not retained" until detail rows are committed (fleet lead, Q5: a separate row).
- [x] 2.2 Obligations: seven-rung ladder, four hatched "never produced"; per-obligation rows "not retained" (Q5).
- [x] 2.3 Claims register from data/claims.yaml (strict subset parser), seeded from design V4, every entry `review: operator-pending` and rendered so (Q6).
- [x] 2.4 Instrument, Glossary, Data pages; data/ publishes history.json, snapshots.jsonl and claims.json with sha256.
- [x] 2.5 Lint rule 3b: unproduced rungs always drawn hatched.

## PR 3 — no auto-deploy, Flutter removed, manual publish
- [x] 3.1 Delete the Flutter app (lib/*.dart, pubspec, test/, web/), its Containerfile, .dockerignore and serve.mjs; scripts/build.mjs keeps only --release-snapshot (no toolchain downloads, no deploy-time collection). The stack ledger drops image:observatorium and the 42 nodes it pulled.
- [x] 3.2 Remove the automatic deploy/observatorium move (1798-khw6 step 4) from scripts/promote-stable.sh; delete scripts/advance-deploy-ref.sh and its Lua fixture; the stable-channel litmus asserts no automation writes the ref.
- [x] 3.3 site/publish.mjs <tag> writes the built site onto the local deploy ref with Observatorium-Release/-Snapshot/-Source trailers and pushes nothing; site/verify.mjs is the pre-deploy stale-ship guard (`npm run deploy` on the deploy branch).
- [x] 3.4 wrangler.jsonc: static assets from ./dist, no build command, 404-page.
- [x] 3.5 methodology/versioning.yaml deploy_refs and openspec/specs/observatorium-dashboard/deployment.md describe the manual operator flow; design.md section 6 rev3.
- [ ] 3.6 Gate step for observatorium npm test with a STEP_SECOND_REGIME attestation (fleet lead routes the second host).

## PR 4 — move the project trace viewer (fleet lead 2026-11-10, option a)
- [x] 4.1 Move observatorium/index.html and lib/*.js to tools/trace-viewer/; --observatorium, tillandsias-embed and scripts/run-observatorium.sh follow; the clickable-trace-index spec and litmus stay green. The flag and the Project observatorium view requirement are unchanged.

## PR 5 — retire the committed CentiColon dashboard
- [ ] 5.1 Delete docs/convergence/centicolon-dashboard.{md,json}; scripts/update-convergence-dashboard.sh defaults to target/; release preflight stops committing it; update the observability-convergence litmus (shape, self-clean evidence), generate-evidence-bundle.sh, test-build-sh-ci-full-install-prep.sh, docs/RELEASING.md step 4 and the cheatsheet, with an observability-convergence spec delta.

## Not in this change
- crates/tillandsias-headless/src/cloudflare_worker_deploy.rs (1853-qr4h) can create a Workers Builds trigger. Untouched; operator question open (fleet lead, 2026-11-10).
- metrics/precompute.mjs is no longer run by any build; its projection tests still guard evidence semantics. Retire it with its tests in a later row.
- openspec/changes/observatorium-deploy-on-stable (1798-khw6) is superseded by this change.
