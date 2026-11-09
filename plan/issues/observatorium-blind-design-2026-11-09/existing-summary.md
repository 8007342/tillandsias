# Existing observatorium (neutral summary, headings as design.md)

Sources read: /home/tlatoani/claudia/tillandsias/observatorium/**, scripts/advance-deploy-ref.sh, scripts/promote-stable.sh (deploy lines), docs/convergence/centicolon-dashboard.{md,json}, scripts/lua/centicolon-grade-observed.lua (header), origin/deploy/observatorium, tillandsias.org docs/audit/2026-11-08-v56.11.7.1.md.

## 1. Information architecture
A single-page Flutter web app (lib/main.dart, ~1000 lines) with a "Repository series" chart panel (range: all/30/90/365 days, log-scale toggle, larger points), a release-evidence chart (lib/evidence_chart.dart), an "Obligation evidence" dialog listing per-obligation rows with filter ("No matching evidence."), a gate-target inventory panel, and a "Refresh evidence" action. A legacy hand-written observatorium/index.html (1516 lines, Chart.js, dark-only, Google Fonts import) still sits in the directory. Separately, docs/convergence/centicolon-dashboard.md/.json is an auto-generated Markdown/JSON dashboard last regenerated 2026-08-09 (890/990-era, "Closed 89.9%", alert red/yellow thresholds). tillandsias.org retired its own score charts on 2026-11-09 and links to the observatorium.

## 2. Visual design
Material/Flutter widgets; series plotted on log10(1+n) with interpolation "none"; scope-change annotations; legacy page dark gradient theme.

## 3. Honesty rules
Enforced in metrics/evidence.mjs and precompute.mjs: residual must equal denominator - satisfied; histogram (declared/traced/positively_tested) must sum; reasons must sum to residual; an unmeasured grade cannot carry a value; release snapshots require litmus records, a valid tag, revision and time; provenance revision must match. Failures become a visible "grade unavailable" gap, not zero. Standing limitation strings (GRADE_LIMITS, RECORD_SCOPE, dirty-tree note, "no retained grade digest"). History is never backfilled. Scope or epoch changes between release cuts are recorded as labelled scope changes.

## 4. Snapshot schema
history/snapshots.jsonl, schemaVersion 1, epoch repository-observation-v1/v2: definitions (source, unit per metric), measuredAt, revision, release, dirty, shallow, current {specs counts, plan states, fragments, residual {value, denominator, satisfied, histogram, reasons, records, provenance{gradeSha256, scopeSha256, limitations}}}, gaps. 7 release rows (v56.10.14.1 .. v56.11.7.1). Every row reports satisfied = 0, residual = denominator (1536 -> 1567 -> 1571); latest reasons: no-binding 1566, unrun 5; dirty = true on the latest.

## 5. Static build pipeline
observatorium/scripts/build.mjs (Node 22): downloads pinned Flutter 3.47.7 and rustup, builds tillandsias-plan with cargo, unshallows git, collects live metrics (display-only) plus committed history, precomputes a projection, runs `flutter build web` into build/web. `--release-snapshot <tag>` appends one row to the committed history at the release cut. Tests: node --test metrics + dart test.

## 6. Deploy workflow
Cloudflare Workers Builds watches refs/heads/deploy/observatorium (wrangler.jsonc, custom domain observatorium.tillandsias.org, SPA fallback). scripts/promote-stable.sh calls scripts/advance-deploy-ref.sh, which advances that branch (fast-forward or restore-merge, verified by tree) on stable promotion/demotion; the push triggers a cloud build and deploy. `npm run deploy` (wrangler deploy) also exists. Deploy branch tip: release bump 56.11.7.1 (2026-11-07).

## 7. Accessibility and mobile
Flutter canvas rendering (CanvasKit/skwasm); no table twin of charts; no explicit a11y work found. Legacy page has viewport meta.

## 8. Additions beyond the L5 obligations
Repository growth series (specs, requirements, scenarios, plan packet states, fragments, commit counts), gate inventory, an in-container local observatorium launcher (scripts/run-observatorium.sh).
