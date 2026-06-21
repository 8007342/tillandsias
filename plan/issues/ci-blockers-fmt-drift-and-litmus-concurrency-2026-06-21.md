# linux-next CI blockers: committed rustfmt drift + concurrency-induced litmus flake

- branch: linux-next
- status: done (fmt fixed); ready (prevention follow-ups)
- owner_host: linux_mutable (coordinator)
- source: meta-orchestration loop e2e step1 (`build.sh --ci-full --install`), 2026-06-21T06:09Z

## Summary

A local-build e2e (step1) on `linux-next` HEAD failed `local-ci` with two
pre-build blockers. One is a real, reproducible defect (fixed here); the other is
a concurrency artifact that does not reproduce.

## 1. Committed rustfmt drift in tillandsias-headless/src/main.rs (FIXED)

`cargo fmt --all --check` flagged 4 unformatted regions in
`crates/tillandsias-headless/src/main.rs` (lines ~3060, 3081, 3292, 4086),
introduced by Linux/headless-scope commits `1973d414` (Order 70/71 init fix),
`dbb90bd9` (tray/init orchestration), and `0bef958b` (github-login push-from-host).
These are core Linux-owned files (not macOS/Windows sibling scopes), so formatting
them is in-scope. Fixed with `cargo fmt -p tillandsias-headless` (targeted to the
one drifting package; diff stayed within main.rs, 33 lines). `cargo fmt --all
--check` now clean.

**Why it slipped through:** the committing cycles ran `--check` / partial gates,
not the full `--ci-full` fmt gate (the known `--check` vs `--ci-full` gap). Every
commit lands on the shared integration branch, so unformatted code blocks the next
host's local-build e2e until someone reformats it.

## 2. litmus:nanoclawv2-mcp-shape transient FAIL (concurrency artifact — NOT reproducible)

The build's `litmus-pre-build` reported `litmus:nanoclawv2-mcp-shape` step 2/7
("verify allowlist enforces 5 approved tools") FAIL with `output=0` for
`grep -c 'nanoclaw\.' crates/tillandsias-nanoclawv2-mcp/src/allowlist.rs`.
Re-running the same grep immediately after returns **14** (passes). The file was
effectively absent/empty during the build window but present afterward —
consistent with a concurrent sibling executing the in-flight **ZeroClaw
migration** (`nanoclawv2/implementation` next_action: "HALT NanoClaw work. Migrate
all existing NanoClawV2 implementation files to ZeroClaw") moving files while my
locked build read the tree. This is an agent-concurrency collision
([[agent-concurrency-collisions-2026-06-20]]): the smoke-lock serializes e2e gates
against each other, but not against an unrelated sibling's source edits.

## Prevention follow-ups (ready)

- id: enforce-fmt-on-commit
  status: ready
  action: >
    Close the --check vs --ci-full fmt gap: add `cargo fmt --all --check` to the
    fast pre-commit/pre-push gate (or the cheap --check path) so rustfmt drift can
    never be committed to a shared branch. Relates to the no-silent-breakage
    principle in [[release-build-monitoring-2026-06-20]].
- id: source-edit-vs-smoke-lock
  status: ready
  action: >
    Decide whether destructive/source-mutating migrations (e.g. ZeroClaw) must take
    the smoke-lock (or a source-edit lease) so concurrent e2e gates don't read a
    half-migrated tree. Likely lightweight: document that file-moving migrations
    acquire the build-install-smoke-e2e lock. Folds into
    [[agent-concurrency-collisions-2026-06-20]].

## Events

- type: finding
  ts: "2026-06-21T06:18:00Z"
  agent_id: "linux-claude-opus48-loop-20260621T0618Z"
  host: linux_mutable
  note: >
    e2e step1 build failed local-ci on linux-next HEAD: real rustfmt drift in
    headless main.rs (fixed via targeted cargo fmt; --all --check now clean) plus a
    non-reproducible nanoclawv2 allowlist litmus FAIL (grep output 0 at build time,
    14 immediately after) attributable to a concurrent ZeroClaw migration moving
    files during the locked build. Discarded the build's generated TRACES/dashboard
    churn; committed only the fmt fix. Filed two prevention follow-ups.
