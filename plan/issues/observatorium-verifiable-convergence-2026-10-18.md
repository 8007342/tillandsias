# Observatorium implementation evidence and repair

@trace order:1782-bek5, spec:observatorium-dashboard

Operator authorization: 2026-10-18 session explicitly permitted changes to the
broken Observatorium app and requested methodology/CentiColon/Lua review,
managed sibling publication and Chromium-framework validation. No tray surface
or core grader algorithm was changed. Worktree: work/1782-bek5, based on
77e34d64e765be5db588b862e4166ab486f657ab.

## Failure and repair

The baseline Flutter release build succeeded, but managed Chromium showed
`Evidence could not be loaded. Unsupported operation: Platform._version`.
The network trace contained no request for data/metrics.json. NetworkAssetBundle
uses an IO HTTP client; the web app now uses package:http's browser transport.
Its loader tests cover success, non-200 failure, periodic refresh, preserving
controls and retaining the last loaded snapshot when a refresh fails.
The startup HTML marker is removed after Flutter's first frame.

The default build previously downloaded its own SDK unless FLUTTER was supplied.
A forge now uses its managed Flutter command and trusted sibling toolchain;
standalone deployment retains the existing URL/checksum-pinned download.

## What CentiColon measures here

methodology/math-foundations.yaml defines finite named obligation states and a
bounded ranking function. methodology/proximity.yaml defines weighted normalized
closure and states that confidence, activity and code size are different things.
The actual centicolon-grade-observed/1 implementation grades scenario obligations
as declared, traced or positively_tested: earned=satisfied, residual=denominator
minus earned. Observatorium now names that schema/unit instead of implicitly
identifying it with the old weighted-gate metric. Higher states are unavailable.

The latest committed release snapshot is v56.10.14.1 at
2247d052e35873638ed9fed5d6f5584c4ce72421: zero earned of 1,536 obligations,
1,534 lacking bindings and two traced but unrun. Its 49,825 global log records
are not 49,825 matching observations. The app previously hid the denominator and
reason counts, and manufactured a recorded-run assertion for any integer
historical residual. It now validates arithmetic, states, reason sums and release
provenance, preserves valid zero-earned observations, and exposes the limitations.
Current working-tree rows are separately inspectable; they never join the
release series. Snapshot changes explicitly begin repository-observation-v2;
older history remains immutable. Denominator/identity changes are scope events.

## Lua simplification

command-runtime remains draft. Its intended architecture is Rust-owned bounded
argv execution with typed results and Lua composition, not shell-string pipes.
The app measures only distinct existing literal targets referenced by
scripts/gate-steps.d/*.step. This observation has 36 Lua and 152 shell targets.
It is a bounded source inventory, not a count of all shell backlog, subprocesses,
verified migrations or runtime performance. Missing/nonliteral targets make the
inventory unavailable. Shell dispatch wrappers may remain among the shell files;
file-count reduction cannot earn CentiColon credit.

## Existing core-grader follow-up, not duplicated

The following source findings corroborate the already-recorded counterexamples
in plan/issues/centicolon-transient-work-scope-research-2026-09-27.md under
1447-9sne. That packet remains ready; the original narrower grader1395-88tp is
completed. This repair documents the limits and does not silently change scoring.

1. Scenario specificity: centicolon-grade-static.lua's ext.obligations loop
   assigns refs[o.req_id] to every scenario. One requirement-level passing test
   can credit multiple scenarios. Existing mutation recipe: two scenario IDs,
   one requirement-bound assertion; only the explicitly covered scenario should
   earn credit under a strengthened contract.
2. Subject/freshness: centicolon-grade-observed.lua only rejects changed spec
   bytes when the record names the same spec and includes a digest. It matches
   passes by test digest without requiring implementation inputs, and keys latest
   results without regime. Existing recipes omit subject digests, name the wrong
   spec/revision, or place a later Windows pass after Linux fail. These must not
   create attributable credit for an unverified subject/regime.
3. Population: centicolon-extract.lua emits invariants separately; the static
   grader consumes only ext.obligations. A fixture containing a named invariant
   must make its inclusion or exclusion explicit. The dashboard now exposes the
   extractor's population, exclusions, invariant count and population gaps.

MCP spec RAG was unavailable (no index); plan_answer also refused the broad grader
question. Canonical file fallback used reason=unavailable; targeted order queries
then verified existing1395-88tp and1447-9sne ownership.

## Verification

22 Node tests pass. Eleven Flutter loader/widget tests pass, including 320px and
390px layouts, missing evidence, filter/inspect behavior, and independent epoch
series with deduplicated controls. Flutter analysis is clean. Release web build
passes through the managed sibling. openspec strict validation passes.

The managed preview uses app_dir target/observatorium-1782-bek5/observatorium,
serving https://www.tillandsias.localhost:18443. Chromium-framework fetched the
metrics JSON, rendered earned/denominator/residual and filtered local-web-preview
to nine rows. Desktop/mobile screenshots and browser checks accompany this file.
The user's separate visible window is owned by the coordinator; cross-owner CDP
returned WINDOW_NOT_FOUND, and the coordinator refreshed its own window.

./build.sh --check ran 3,134 workspace tests and failed exactly five known
1780-jxc3 environment cases: four CA refresh tests need missing openssl, and
spec_index::the_repo_relative_rung_anchors_to_the_checkout_not_to_home rejects
this forge's cache TMPDIR. All reached formatting, Clippy and plan checks passed.
The app repair does not claim a green whole-repository gate.
