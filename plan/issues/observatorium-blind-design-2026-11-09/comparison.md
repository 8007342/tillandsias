# Comparison: blind design vs existing observatorium

Protocol: method.md section 3. Rubric (rubric.md) written before reading either design. Coin flip `shuf -n1 -e X Y` -> X, so **X = blind design, Y = existing**. Scored as X/Y, unblinded after. One judge only (deviation from method step 3: no second independent judge).

## 1. Scores

### A. Obligation coverage (0-2; N = neutral 1 each)
| ID | X | Y | Evidence |
|---|---|---|---|
| L5-01 | 2 | 1 | X: obligations table, tombstoned column; Y: scopeSha256 identity change only |
| L5-02 | 2 | 1 | X: 7-rung histogram + ladder; Y: 3-state histogram (declared/traced/pos_tested) |
| L5-03 | 2 | 1 | X: added/retired/renamed + alignment panel; Y: denominator/epoch change labels |
| L5-04 | 2 | 0 | X: V4/V5 property-test ledger with scope caveat; Y: none |
| L5-05 | N1 | N1 | |
| L5-06 | N1 | N1 | X shows bar_changes; unmeasurable evidence form |
| L5-07 | N1 | N1 | |
| L5-08 | N1 | N1 | |
| L5-09 | 2 | 1 | X: goalposts ledger beside chart; Y: scope changes annotated, invalidation not tracked |
| L5-10 | N1 | N1 | |
| L5-11 | 2 | 0 | X: two projections labelled; Y: one residual |
| L5-12 | 2 | 2 | both commit a durable history (X history.jsonl, Y history/snapshots.jsonl) |
| L5-13 | N1 | N1 | |
| L5-14 | 1 | 2 | Y: GRADE_LIMITS states shared requirement bindings; X: listed in serves but no card |
| L5-15 | 2 | 2 | both: no interpolation, breaks at regime/epoch change |
| L5-16 | N1 | N1 | |
| L5-17 | N1 | N1 | |
| L5-18 | 2 | 0 | X: withdrawn-claims register; Y: none |
| L5-19 | 2 | 1 | X: standing visible disclaimer; Y: limitation strings, not the adequacy disclaimer |
| L5-20 | N1 | N1 | |
| L5-21 | 2 | 1 | X: two integers first + probability lint; Y: integer arithmetic validated, but legacy docs/convergence prints "Closed 89.9%" with red/yellow alert |
| L5-22 | 2 | 0 | X: weight table + "rich policy not implemented"; Y: none |
| L5-23 | 2 | 1 | X: deploy trailer must match snapshot; Y: release rows stamped, but stale Aug dashboard still committed and build adds live (unreleased) metrics |
| L5-24 | N1 | N1 | |
| L5-25 | 2 | 0 | |
| L5-26 | 2 | 0 | |
| L5-27 | 2 | 0 | |
| L5-28 | 1 | 0 | X lists it as open claim only |
| L5-29 | N1 | N1 | |
| **Sum /58** | **45** | **24** | |

### B. Cross-cutting (0-4)
| | X | Y | Evidence |
|---|---|---|---|
| C1 Honesty | 4 | 3 | Y's validator is real and strict; loses a point for the stale 89.9% artefact |
| C2 Non-technical fit | 3 | 1 | Y: log-scale repo counts, "0 tested of 1571" with no plain explanation |
| C3 Technical auditability | 3 | 3 | Y: provenance digests, reasons; X: digests + data/ route, but assumes data that may not exist |
| C4 Static site in ./observatorium | 4 | 1 | Y: Flutter + cargo + network toolchain downloads at build; SPA |
| C5 Manual deploy branch, no auto-deploy | 3 | 0 | Y: Workers Builds auto-builds on branch push; promote-stable moves branch by script; live metrics at build |
| C6 Visual/a11y | 3 | 2 | X: table twins, glyph+text, mobile; Y: canvas-rendered, no twins |
| C7 Implemented | 0 | 4 | X is paper |
| **Sum /28** | **20** | **14** | |

**Totals: X (blind) 65/86; Y (existing) 38/86.** Excluding C7, 65 vs 34. The gap is mostly in obligations Y never targeted (claims, property tests, weights, escape hatch), not in shared ones.

## 2. Diversity (where they differ, who is right)
- Rendering: X build-time SVG + HTML, JS optional; Y Flutter canvas SPA. **X right** for static, a11y, low-end hosts, honesty fallback tables.
- Build inputs: X reads committed snapshots only; Y also collects live metrics at deploy time. **X right**: a deploy-time live number is not a release measurement (L5-23).
- Validation: Y has working arithmetic/provenance validators; X specifies lint rules on paper. **Y right in substance**; keep its validator, add X's lint.
- Scope breaks: both. Y detects via denominator/epoch/scopeSha256 (real); X adds rename map and aligned-scope recompute. Combine.
- Claims/retractions: only X. **X right** (the input document's main content is retractions).
- Repo growth series: only Y. Neither obligation-traced; demote to an "activity" page labelled as not progress.
- Deploy: Y automatic cloud build on branch move; X manual local build, committed dist on deploy branch. **X right** under the stated constraint.
- Data honesty Y has that X lacks: explicit "reasons" decomposition (no-binding vs unrun). **Y right**; X should adopt it.

## 3. Shared weaknesses (defects in the level-5 document)
- Neither can show per-platform attribution or runtime_obs/evidence_bundled witnesses: the spec defines no required-platform set or exportable witness.
- Neither has a defined `d_v`; both fall back to the CentiColon residual.
- Neither can render workstream residuals (L5-17), K (L5-10), or operator-decision evidence (L5-06).
- 11 of 29 obligations are unmeasurable as written; Y did not silently measure any of them (no neutral-scoring finding against the text beyond the 13 already flagged).

## 4. Top learnings
1. **The live headline is 0 of 1571 satisfied in every release row** (latest reasons: 1566 no-binding, 5 unrun). Y renders it honestly but without explanation; the real defect is the grader's binding population, not the dashboard. Any rebuild must lead with "obligations not yet bound to tests: 1566" rather than a bare residual, or the first screen reads as total failure.
2. **There are two dashboards and one is stale.** docs/convergence/centicolon-dashboard.* (Aug 2026, 89.9% closed, red alert) is exactly the L5-23 defect and contradicts the observatorium (0%). Retire it or stamp it "historical, not this release".
3. **Y violates the deploy constraint structurally**: Cloudflare Workers Builds watches deploy/observatorium and promote-stable.sh advances it automatically; the build also fetches Flutter/rustup and collects live metrics. Manual-only requires removing the Workers Builds trigger and building locally.
4. **Y's strongest asset is its evidence validator** (residual arithmetic, histogram sums, reasons sum, provenance revision match, unavailable-not-zero, never-backfilled history). X had to invent the same rules; reuse Y's code.
5. **X's strongest asset is the claims/strength register and goalposts ledger**: the level-5 document is mostly scoped claims and retractions, and Y has nowhere to show them. Also X's commit-trailer = snapshot check is a cheap offline stale-ship guard.
6. **Per-obligation rung data exists only as 3 states** (declared/traced/positively_tested); X's seven-rung views would render mostly "not recorded" until the grader emits neg_tested..evidence_bundled.
7. **Single judge**: protocol asked for two blind judges; scores should be treated as one rater's.

## 5. Keep from each
- From Y: evidence.mjs validators and limitation strings; committed history/snapshots.jsonl as the durable baseline (append at release cut only); scope/epoch change detection; reasons decomposition; release tag regex and provenance checks; node --test suites.
- From X: page set V1-V6; build-time SVG with table twins, JS-optional; honesty lint (null->0, ratio without integers, probability words, stamp on every page, no connecting across breaks); goalposts ledger beside the chart; claims register with strength categories; weight table + "rich policy not implemented"; instrument page; trailer check on the deploy commit; per-obligation pages.
- Drop: Flutter app and its pinned toolchain download; live deploy-time metrics; legacy index.html (Google Fonts, Chart.js, dark-only); docs/convergence auto-dashboard (or freeze as labelled history); 60 s metrics cache comment; Workers Builds trigger.

## 6. Recommended target design
1. **Source**: ./observatorium contains `data/` (committed history/snapshots.jsonl extended with X's fields as optional, plus data/claims.yaml hand-maintained), `build/` (one Node script, no network, no cargo, no Flutter), `templates/`, `static/`. Snapshot written only by `--release-snapshot <tag>` at the release cut.
2. **Build**: `node observatorium/build.mjs --release <tag>` -> `observatorium/dist/`: plain HTML/CSS + inline SVG step charts with `<table>` twins; runs Y's validators then X's honesty lint; fails closed. JS only for table filter.
3. **Pages**: Home (stamp; two integers; "bound to tests / unbound / unrun / tested" bar from reasons; step chart with breaks; goalposts ledger; standing disclaimer; plain-English one-paragraph reading for non-technical readers), Releases, Obligations (+ per-obligation), Claims, Instrument, Glossary, Data. Rungs not recorded shown hatched "not recorded".
4. **Publishing**: operator, after a release, runs build locally, inspects, then `observatorium/publish.sh <tag>` replaces the tree of deploy/observatorium with dist/ and commits with `Observatorium-Release:` and `Observatorium-Snapshot:` trailers, refusing on mismatch or older release; operator pushes by hand. Remove the advance-deploy-ref call from promote-stable.sh and the Workers Builds build command; the host serves the committed static files only (no build step on the host). No cron, hook or CI anywhere moves the branch.
5. **Housekeeping**: freeze docs/convergence dashboard with a "historical snapshot of 2026-08-09, not a current measurement" banner or delete it; tillandsias.org keeps linking to the observatorium only.
6. **Upstream asks** (spec defects): define d_v := residual under policy P; define required platforms per obligation; define exportable witnesses for runtime_obs/evidence_bundled; fix the grader binding population before publicising the score.
