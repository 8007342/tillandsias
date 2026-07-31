# CAPTURE: expert ground-truth harness is RED on linux-next HEAD

- date: 2026-07-31
- class: optimization/ (committed test RED on mainline; blocks `cargo test -p
  tillandsias-plan` and the expert-groundtruth litmus for every host)
- found by: order-547 implementation cycle (incidental — running the full crate
  test suite before committing an orthogonal new module; the RED is NOT from
  this cycle's work)
- host: yoga (linux_immutable), branch linux-next

## What

`cargo test -p tillandsias-plan` fails:
`groundtruth::tests::the_committed_query_set_is_green_at_head` is RED. Verified
pre-existing (reproduces with this cycle's `spec.rs`/`lib.rs`/`main.rs` edits
removed — those add an inert module and cannot affect the grader). The committed
query set `openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml` has
drifted from the current `plan/index.yaml`:

- `plan-status-of-394a` expects packet `plan-methodology-experts-rung1/
  plan-expert-binary-shipping` (order 394a) with `status: done`, but the ledger
  now has `status: completed` (plan/index.yaml:16145-16147). Closest-miss the
  grader reports: `authority.status = "completed", expected "done"`.
- `plan-active-release-experts-milestone` expects a citation to packet
  `experts-construction-research` (status done) and to 394a (status done); the
  grader's closest miss lands on `forge-hot-path-placement-metrics` / order 329
  instead — packet identity/ordering drift.

Root cause: the status-vocabulary normalization (order 440, "normalize status
vocabulary") and subsequent ledger reorganization changed packet statuses
(`done` -> `completed`) and layout WITHOUT updating the committed ground-truth
query set that pins the old vocabulary. The grader is corpus-agnostic and
correct; the fixture is stale.

## Why it matters

The expert ground-truth harness is the falsifiable closure for the whole local-
expert milestone (orders 393/394/547-552 all cite it as their grading gate). A
RED committed set means every host's `./build.sh`/`cargo test` and the
`litmus:expert-groundtruth-harness` go red for reasons unrelated to the work
under test, masking real regressions — the same class as the no-python breach
(order 545).

## Smallest next action (for the experts/394 packet owner)

Reconcile `openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml` with
the current ledger: update the expected `status` values from `done` to
`completed` where the packets are genuinely completed, and re-point the
`experts-construction-research` / 394a expectations to the packets' current
identities/orders. Then `cargo test -p tillandsias-plan` and
`litmus:expert-groundtruth-harness` go green. This is a fixture refresh, not a
grader change — do NOT weaken the grader. Owned by the experts milestone since
it pins that milestone's exemplar queries.

## Not in scope here

This cycle implements order 547 (the spec RAG index) — a new, orthogonal module
whose own 6 unit tests pass and which builds clean. This finding is filed per the
capture rule and left for `/advance-work-from-plan` pickup; it is intentionally
NOT fixed in the 547 commit (correct fixture values are the packet owner's call).
