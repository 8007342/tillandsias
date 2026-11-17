# Rubric (built before reading either design)

Sources: derivation.md L5-01..L5-29 (union with level-5-phd.md obligations; no extra obligations found beyond those 29 in the input), plus the coordinator constraints.
Scale per row: 2 covered and verifiable, 1 partial, 0 absent. Rows marked N are flagged unmeasurable/ambiguous as written (derivation §5) and are scored neutrally (1 each side) unless a design actively misrepresents them (then 0).

## A. Obligation coverage (29 rows)
| ID | Pass condition | N? |
|---|---|---|
| L5-01 | ID set, duplicates, tombstones and gate verdict visible | |
| L5-02 | per-obligation rung and rung histogram | |
| L5-03 | added/retired/renamed per release; comparability stated | |
| L5-04 | property tests named with scope caveat | |
| L5-05 | stability distinct from completion | N |
| L5-06 | bar per release, raise log with operator provenance | N |
| L5-07 | residual series with regression flags; zero not claimed | N |
| L5-08 | scope, weights, policy version shown with residual | N |
| L5-09 | new/retired/invalidated never counted as progress | |
| L5-10 | cycles since last decrease; bound marked conditional | N |
| L5-11 | weighted vs unweighted shown as distinct projections | |
| L5-12 | durable baseline existence disclosed | |
| L5-13 | platform attribution gap shown | N |
| L5-14 | shared scenario candidates disclosed | |
| L5-15 | regime Broken drawn as break | |
| L5-16 | aligned-scope comparison only | N |
| L5-17 | per-workstream residuals not pooled; retractions first-class | N |
| L5-18 | withdrawn-claims register | |
| L5-19 | closure disclaimer attached to figures | |
| L5-20 | credit = at-bar, not top; CI pass = pos_tested | N |
| L5-21 | denominator and residual always beside ratio; never probability | |
| L5-22 | weight table in force + "rich policy unimplemented" | |
| L5-23 | every figure stamped with release/build; stale snapshot impossible | |
| L5-24 | LOC ratio and 5000-line flag, labelled unenforced | N |
| L5-25 | fold property tests; associativity untested | |
| L5-26 | falsified descents counted | |
| L5-27 | claim registry with strengths | |
| L5-28 | version shown with live meaning | |
| L5-29 | unknown-event intake count | N |

## B. Cross-cutting (each 0-4)
- C1 Honesty rules (missing != zero, dated+sourced, denominators, breaks)
- C2 Non-technical reader fit
- C3 Technical reader auditability
- C4 Static site under ./observatorium, buildable offline from repo data
- C5 Manual deploy-branch publishing after release, no auto-deploy anywhere
- C6 Visual quality / accessibility
- C7 Implemented (exists and runs) vs. paper

Max: A 58 + B 28 = 86.
