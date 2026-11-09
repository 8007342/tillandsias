# Observatorium design (blind, rev2)

A small static site that shows a software project's progress against its own
named obligations, built from one locally produced snapshot per release and
published by a manual `wrangler deploy` from a deploy branch that holds
source. Every `serves:` line traces to `derivation.md`.

**rev2 summary.** Revised after `out/answers.md`. Changes are marked
`rev2: Qn`. The three that reshape the design: the grader produces only
three states (declared, traced, positively_tested) and a count residual —
no bars, weights, penalties or caps (Q2, Q7); a committed per-release
history `history/snapshots.jsonl` already exists and becomes the primary
input (Q4); hosting is a Cloudflare Worker serving static assets whose build
runs on the operator's machine at deploy time, from a deploy branch that
holds source, not `dist/` (Q11). Live numbers to design for: denominator
1571, satisfied 0, declared 1566, traced 5 (Q2). The front page will
therefore say "1571 of 1571 unmet", and must say it plainly.

## 1. Information architecture

```
/                       V1  Front page: "Is it getting better?"
/releases/              V3  Release index (table of releases, regimes)
/releases/<version>/    V3  One release: stamp, numbers, diff, alignment
/obligations/           V2  Obligations table (client-side filter/sort)
/obligations/<id>/      V2  One obligation: rung vs bar, history, evidence links
/claims/                V4  Hypotheses & claims register (proved/tested/open/withdrawn)
/instrument/            V5  Instrument health (property tests, complexity, escape hatch)
/glossary/              V6  What a CentiColon is and is not; rung definitions
/data/                      Published snapshot files (the audit trail)
```

Seven page kinds, two of which are generated per item. Navigation: a
single top bar (Home · Releases · Obligations · Claims · Instrument ·
Glossary · Data). Every page footer: `release <v> · built <UTC> · snapshot
sha256 <first 12> · generator <ver>` (serves L5-23, M9).

### V1 Front page — serves L5-07, L5-08, L5-09, L5-15, L5-18, L5-21; M1–M8

Order of blocks, top to bottom:

1. **Stamp line.** "Measured at release 2026.11.09.3, built 2026-11-09 18:02
   UTC." Never a relative time ("3 days ago") because the page is static.
2. **Residual, as two integers.** *rev2: Q2, Q7, Q11-adjacent.* There is one
   live projection, a count: `Obligations without a positive test: 1571 of
   1571` with a small secondary `100% unmet` labelled *share, not
   probability*. The weighted CentiColon score does not exist in the live
   grader, so the "two projections" row is replaced by one line: "A weighted
   score (policy `proximity`) is declared but not computed; the legacy
   890/990 figure (scheme `centicolon-signature`, last 2026-08-09) is a
   different, older scheme and is shown only on /instrument/ as historical"
   (serves L5-11, L5-22, L5-23).
   Beneath: **why unmet** — the per-row reasons histogram the grader already
   emits (`no-binding`, `unrun`, `failed`, `skipped`, `spec-changed`). This
   is the single most informative figure available today: it distinguishes
   "no test exists" from "test failed" from "spec moved under the test".
3. **Residual over releases (step chart).** x = release, y = residual.
   *rev2: Q4.* Regime comes from the ratchet vocabulary, not an invented
   Comparable/Broken: `baseline`, `monotone`, `scope-added` (combinable).
   Additionally the build derives `scope-changed` when `scopeSha256` differs
   between consecutive rows, and `denominator-changed` when the denominator
   differs. Any of scope-added / scope-changed / denominator-changed draws a
   vertical break with the reason in a visible footnote list under the chart;
   points after a break are not connected to points before it. Regressions
   (residual up vs previous row within the same segment) are filled red
   markers and listed in text. Rows missing `residual.measured` or
   `histogram` (the first row, v56.10.14.1) render as a hatched gap, not as
   zero.
4. **Goalposts ledger (small table).** Per release: denominator delta,
   `scopeSha256` changed?, population gaps (`unregistered`, `missing`,
   `unkeyed`), excluded counts (`deprecated`, `obsolete`, invariants
   excluded: 126). *rev2: Q1, Q4.* Bar raises are dropped from the ledger:
   there is no per-obligation bar in the grader; the only bar is
   positively_tested, global. If the bar ever changes it is a policy-version
   row (serves L5-09, L5-06, L5-16).
5. **Progress premise status.** One sentence: "Releases since last strict
   decrease: 4. The project has not declared a K; no eventual-zero claim is
   made." (serves L5-10).
6. **Retractions.** Count of withdrawn claims with link to /claims/ (L5-18).
7. **Standing disclaimer**, visible not collapsed: closure proves neither
   adequacy of the obligation set nor behaviour of all executions (L5-19).

### V2 Obligations — serves L5-01, L5-02, L5-03, L5-13, L5-20; M4, M5, M12, M16, M17

*rev2: Q1, Q2, Q5, Q10.* Table columns, restricted to fields the grader
emits: ID · spec · requirement id · title · state (declared / traced /
positively_tested) · reason (for non-satisfied rows) · Δ since previous
release · spec digest (short). Dropped: kind, workstream, bar, weight,
tombstoned (no such per-obligation fields exist); platforms (not a grader
dimension; `host` is a machine name and must not be published). Filters:
spec, state, reason, changed. Above the table: a **rung histogram** with all
seven rungs in chain order; the three populated rungs are solid bars, the
four never-assigned rungs (`absent`, `negatively_tested`, `runtime_observed`,
`evidence_bundled`) are drawn as hatched empty slots labelled "never produced
by any grader" (serves L5-02, L5-20: the lattice exists on paper only, and
the page says so rather than pretending the three states are the whole
ladder).

Per-obligation page: the seven-rung ladder vertically, the single global bar
(positively_tested) marked, the reached rung filled, unproduced rungs
hatched; reason text; a history strip (release → state) populated only for
releases where per-row details were committed (see §4); link to the spec
path at the release tag. This page requires per-release detail rows to be
committed (Q16); until then the list page is built from the latest local
`grade.json` at build time and the history strip is shown as "not retained".

### V3 Releases — serves L5-03, L5-15, L5-16, L5-23; M9, M10, M11

*rev2: Q3, Q4, Q12.* Index: one row per `snapshots.jsonl` line: release tag
(`v56.11.7.1`, rendered beside its decoded date 2026-11-07 build 1 and the
`measuredAt` UTC instant) · revision (short SHA) · dirty/shallow flags ·
denominator · satisfied · residual · histogram (3 populated states) ·
ratchet regime · derived scope/denominator change · gaps. `stable` is not
recorded in the history; the index shows "stable: not recorded" until Q15 is
settled. A `dirty: true` row is rendered with a visible "measured on a dirty
tree" badge; the build does not drop it.

Release page: the stamp block; the three integers; reasons histogram;
regime; **alignment panel** against the previous row: `scopeSha256` equal or
not; if per-row details exist for both releases, IDs common / only-before /
only-after and the residual recomputed on the intersection (M11) labelled
"aligned-scope comparison"; if not, the panel states "per-obligation rows
not retained for <release>; alignment not computable". Provenance digests
already present (`gradeSha256`, `obligationsSha256`, `staticSha256`,
`scopeSha256`) are printed in full with their definitions (Q14).

### V4 Claims — serves L5-04, L5-18, L5-19, L5-21, L5-25, L5-27, L5-28; M13, M14

A register table: claim · strength (`proved` / `property-tested` / `tested by
name` / `external analogy` / `assumed` / `open` / `withdrawn` / `on paper
only`) · scope note · since release · what would discharge it. *rev2: Q2,
Q7, Q9.* A new strength category `on paper only` is needed for the
seven-state lattice (four rungs never assigned), the weighted scoring
policy, and the penalties/caps: declared in methodology, read by no code.
Property-test entries stay at "test name not resolved" until Q20 is
answered. Seeded from the document: Prop. 1
(proved, model only), Theorem 3 hypotheses (monotone, inflationary:
property-tested over committed rules per the document, names unconfirmed;
live validators: open), idempotence (same), contraction (open: needs metric, completeness, constant), Galois
connection (open), strong law (withdrawn), CRDT fold (commutativity,
idempotence tested; associativity untested), semantic merge (external
analogy), progress premise (open), versioning semantics (documentation
defect, open). Colour is by strength category only; no traffic lights that
imply pass/fail where the status is "open by design".

### V5 Instrument — serves L5-12, L5-13, L5-14, L5-22, L5-24, L5-26, L5-29; M13, M15, M17, M18

*rev2: Q4, Q5, Q6, Q7, Q8, Q9.* Cards:
- Property-test ledger: names unconfirmed (Q9/Q20); until confirmed the card
  lists the three refinement properties and three fold properties with
  status "test name not resolved" rather than inventing names.
- Complexity ratio: three LOC integers counted at build time, the ratio, the
  0.15 and 5000-line thresholds, label "unenforced; measured by LOC as an
  interpretation"; alongside, the gate-target counts already published
  (`lua_gate_targets`, `shell_gate_targets`).
- Scoring policy: "declared weights (proximity.yaml) and 16 penalties / 6
  caps: not read by any code"; the legacy `centicolon-signature` dashboard
  (29 records to 2026-08-09, 890/990) shown as a historical series in its
  own box, with "different scheme; not comparable to the count residual".
- Baseline: "durable: `history/snapshots.jsonl` (committed); ratchet
  baseline `last.txt`: host-local, untracked".
- Platform attribution: a single sentence, "platform is not a grading
  dimension; results carry a machine name only, which is not published";
  the obligation × platform matrix is removed (there is nothing to fill it).
- Runtime observation: "no code assigns `runtime_observed`; the separate
  runtime metrics (cpu/memory/disk) are not tied to obligations and are not
  shown here".
- Escape hatch counts: kept only if the ledger export exposes them (Q open).

### V6 Glossary — serves L5-02, L5-20, L5-21

Plain-language definitions of the seven rungs, "bar", "credited",
"denominator", "regime", and a boxed "What a score is not": not a probability,
no complement rule, not comparable across a Broken regime, not proof of
adequacy.

## 2. Visual design

- **Palette**: neutral greys for structure; one accent for "credited";
  one for "regression"; one for "no data / not attributed" (hatched, never a
  colour that reads as a value). Colour never carries meaning alone: every
  state also has a glyph or text.
- **Charts**: step charts for release series (a residual is constant between
  releases; a line would invent interpolation). Horizontal bar for the rung
  histogram. Ladder glyph for a single obligation. No pie charts: parts do not
  sum (L5-21 non-additivity). No gauges or "health scores".
- **Typography**: system font stack, 16px base, tabular numerals for tables.
- Inline SVG generated at build time; no chart library at runtime. A `<table>`
  twin of every chart is present in the DOM (visually collapsed, expandable),
  which is both the accessibility fallback and the honesty fallback.

## 3. Honesty rules (fixed before the visuals, enforced by the build)

1. **Missing is missing.** A field absent from the snapshot renders as "—
   not recorded" with a hatched cell; the build fails if any renderer maps
   `null` to `0`.
2. **Two integers before any ratio.** A ratio may not appear without its
   numerator and denominator on the same line.
3. **Breaks are breaks.** *rev2: Q4.* Series are segmented by regime;
   segments are never connected across `scope-added`, a `scopeSha256`
   change, a denominator change, or a scheme change (the legacy
   centicolon-signature series and the count residual are never on one axis).
3b. **Unproduced states are drawn as unproduced.** *rev2: Q2.* The four
   rungs no grader assigns are always shown hatched with their label; the
   build fails if a renderer omits them from the ladder or renders them as a
   zero-height bar without the hatch.
3c. **No machine names.** *rev2: Q5, Q10.* The build strips `host` from any
   detail row before writing `/data/`; the lint fails if a published JSON
   contains a `host` key.
4. **Every figure is stamped** with release and UTC build time; relative
   times are forbidden.
5. **No probability words.** The lint rejects "confidence", "likelihood",
   "chance", "%" without the words "share of" in generated text (L5-21).
6. **Goalposts move visibly.** Any release with added/retired/renamed IDs or
   a bar change must show the ledger entry on the front page for that release.
7. **Claims carry strength.** Any statement of a property names its strength
   category from V4.
8. **A stale snapshot cannot ship.** *rev2: Q11.* The deploy branch holds
   source, so the check moves into the build that wrangler runs at deploy
   time: the build refuses if the last line of `history/snapshots.jsonl` has
   a `release` that is not the most recent `v*` tag reachable from HEAD, or
   if the deploy branch HEAD commit lacks a trailer
   `Observatorium-Release: <that release>`. The page footer stamp is then
   guaranteed to name the release the data measures.
9. **Unverifiable rungs say so.** Rungs with no exportable witness are
   displayed with the suffix "(claimed by grader)".

## 4. Snapshot schema

*rev2: Q1, Q2, Q4, Q7, Q10, Q14.* The primary input is the existing committed
`history/snapshots.jsonl` (one object per release; keys: schemaVersion,
epoch, definitions, measuredAt, revision, release, dirty, shallow, current,
gaps; `current.residual` holds value/denominator/satisfied/measured/
histogram/reasons/records/provenance). The site does **not** define a rival
history. It defines two things on top:

1. A **derived, published view** `/data/history.json` produced at build time
   from `snapshots.jsonl`: one record per release with the fields the pages
   need, segment ids computed from regime/scope/denominator changes, the
   decoded date, and nulls preserved where the row lacks a key (first row:
   no `measured`, no `histogram`).
2. An **optional per-release detail file** `history/details/<release>.json`
   (new, Q16): the grader's per-obligation rows (`id, req_id, spec, state,
   reason, spec_digest`) with `host` and `regime` removed at write time.
   Without it the obligations pages work from the latest local `grade.json`
   only and say so.

The schema sketched below is therefore the *published view*, not a new
producer contract. Fields the grader cannot supply are kept as explicit
nulls so the pages render them as "not recorded", and so the schema
documents the gap between the paper lattice and the live grader.

```jsonc
// /data/history.json — one element per release, derived at build time
// from history/snapshots.jsonl. Illustrative; nulls are deliberate.
{
  "schema": "observatorium/1",
  "release": {"tag": "v56.11.7.1", "date": "2026-11-07", "build": 1,
              "stable": null,                       // rev2: Q3 — not recorded in history (Q15)
              "measured_at": "2026-11-07T…Z", "revision": "abc123…",
              "dirty": false, "shallow": false, "epoch": "repository-observation-v2"},
  "provenance": {"grade_sha256": "…", "obligations_sha256": "…",
                 "static_sha256": "…", "scope_sha256": "…",
                 "record_scope": "…", "limitations": ["…"]},
  "residual": {
    "denominator": 1571, "satisfied": 0, "value": 1571,
    "measured": true,                                 // null on v56.10.14.1
    "histogram": {"declared": 1566, "traced": 5, "positively_tested": 0,
                  "absent": null, "negatively_tested": null,
                  "runtime_observed": null, "evidence_bundled": null},   // rev2: Q2 — never produced
    "reasons": {"no-binding": 0, "unrun": 0, "failed": 0, "skipped": 0, "spec-changed": 0},
    "bar": "positively_tested"                        // rev2: Q2 — single global bar
  },
  "segment": {"ratchet_regime": "monotone",            // rev2: Q4 — baseline|monotone|scope-added
              "scope_changed": false, "denominator_changed": false, "segment_id": 2},
  "regression_vs_previous_in_segment": false,
  "releases_since_last_strict_decrease": null,       // null until a decrease has ever occurred
  "population": {"excluded": {"deprecated": 0, "obsolete": 0}, "invariants_excluded": 126,
                 "gaps": {"unregistered": 0, "missing": 0, "unkeyed": 0}},
  "specs": {"files": 0, "requirements": 0, "scenarios": 0},
  "plan": {"total": 2397, "states": {}, "fragments": 5880},
  "details_available": false                          // rev2: Q16 — history/details/<release>.json present?
}
```

Removed from rev1 (fields the live system does not have): weighted
`earned`/`total_cc`, per-obligation `kind`, `workstream`, `bar`, `weight`,
`tombstoned`, `platforms`, `bar_changes`, `renamed`. Each removal is a
documented gap on /instrument/ rather than a silent omission.

Plus hand-maintained files, not per release:

- `data/claims.yaml`: the V4 register (`id, statement, strength, scope,
  since, status, discharge`).
- `data/legacy-centicolon-signature.json`: the 29 historical records of the
  older weighted scheme, copied once, scheme-labelled, never merged with
  the count residual (*rev2: Q7*).

Validation: a JSON Schema in `schema/observatorium-view-1.json` for the
derived view; `snapshots.jsonl` continues to be validated by its own
existing checker (Q4 names one). The build fails on violation; unknown
fields are allowed and ignored; missing fields are rendered as missing, not
defaulted.

## 5. Static build pipeline (local)

*rev2: Q4, Q11.* The existing release step already appends to
`history/snapshots.jsonl` at release cut; the site build consumes it.

```
(existing) release cut        → appends history/snapshots.jsonl
(new, optional) obs-details   → history/details/<release>.json (host stripped)   Q16
obs-build                     → build/web/  (derive view → validate → render → lint)
wrangler deploy               → runs build.command = obs-build, uploads build/web/   (manual)
```

- Generator: one small Node ≥ 22 script with no runtime dependencies, since
  Node is already the build toolchain on the deploy path (Q11). It replaces
  the Flutter web build for this site (see Q17); the output is multi-page
  HTML, so `not_found_handling` moves from `single-page-application` to a
  real `404.html`. Templates render HTML; SVG charts are rendered from the
  same data; a `<table>` twin is emitted per chart.
- Lint step (honesty rules §3): null→0 check, ratio-without-integers check,
  forbidden-word check, stamp present on every page, segment-connectivity
  check against regime, unproduced-rung hatch check, no `host` key in
  `/data/**`, release-tag ↔ trailer match.
- Output is pure files under `build/web/`: HTML, CSS, SVG, `/data/**` JSON.
  `build/` stays git-ignored. Total size target < 5 MB for 100 releases.
- `_headers`: keep `/data/*` at `max-age=60, must-revalidate`; HTML
  `no-cache`; SVG/CSS content-hashed and immutable.
- Client-side JS is limited to the obligations table filter/sort and the
  chart↔table toggle; the site is complete with JS disabled.

## 6. Manual deploy-branch workflow

*rev2: Q11.* The deploy branch (`deploy/observatorium`) holds the **source
tree** including `wrangler.jsonc` and `history/snapshots.jsonl`; nothing
built is committed. The Worker is deployed only by a person running
`wrangler deploy` on their own machine; no Workers Builds trigger is in
effect and none is added.

1. After a release is cut and `snapshots.jsonl` has its new line on the
   trunk: optionally run `obs-details <release>` and commit the stripped
   detail file.
2. Fast-forward `deploy/observatorium` to the release commit (the branch
   only moves forward); the fast-forward commit, or an empty commit on top,
   carries the trailer `Observatorium-Release: <tag>`.
3. On the operator machine, in a checkout of `deploy/observatorium`: `npm
   run build` locally and inspect `build/web/` with a static file server.
   The build refuses (honesty rule 8) if the history's last release, the
   newest reachable `v*` tag, and the trailer disagree.
4. `npm run deploy` (= `wrangler deploy`), which re-runs the build and
   uploads the assets. Authentication is the operator's; nothing is stored
   in the repo.
5. Push `deploy/observatorium` by hand so the published state is
   reconstructible from a ref. No hook, cron, or CI trigger.
6. Rollback = check out the previous deploy-branch commit and `wrangler
   deploy` again; the footer stamp makes the served state self-describing.
   The branch itself is not rewound.

Why the trailer: the honesty rule "a stale snapshot cannot ship" (L5-23) needs
a check that runs without network and without trusting the deployer's
memory. Comparing the trailer, the tag and the history's last line is that
check, and it runs inside the same build wrangler invokes.

## 7. Accessibility and mobile

- Semantic HTML: `<main>`, `<nav>`, `<table>` with `<th scope>`, landmarks,
  skip link. Headings in order.
- Every SVG chart: `role="img"`, `aria-labelledby` pointing to a visible
  title and a one-sentence text summary ("Residual fell from 140 to 100 over
  six comparable releases; one break at 2026.10.02"); the `<table>` twin is
  reachable by keyboard.
- Colour contrast ≥ 4.5:1; states encoded by glyph + text, never colour
  alone; hatched "no data" pattern.
- `prefers-color-scheme` honoured with the same palette roles; `prefers-reduced-motion`
  irrelevant (no animation).
- Mobile: single column at < 720px; tables become stacked cards with
  label/value pairs; the step chart keeps its height and scrolls
  horizontally with the latest release visible first; 16px gutters, no
  horizontal page scroll; tap targets ≥ 44px.
- No fonts or scripts loaded from third parties; works offline from a file
  URL.

## 8. Designer's additions (no L5 trace)

- Glossary page V6 as a separate route (traceable content, untraced *placement*).
- *rev2: Q4* — the rev1 proposal of a site-owned `history.jsonl` is
  withdrawn; the committed `history/snapshots.jsonl` is the baseline. The
  only addition is the optional stripped per-release detail file (Q16).
- Reasons histogram as a front-page block (the document does not mention the
  grader's reason taxonomy; it is the most useful datum the grader emits).
- Search-free: deliberately no search box; the obligations filter suffices.
- *rev2: Q11* — replacing the Flutter web client with generated multi-page
  HTML is a designer's choice, not an obligation; see Q17.
