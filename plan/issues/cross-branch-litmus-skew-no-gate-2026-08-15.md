# Cross-branch litmus skew has no gate until the coordinator's full run (754-kptj)

- Date: 2026-08-15
- Host: linux_mutable (coordinator), attended meta-orchestration cycle
- Class: enhancement/ (gate coverage)
- Packet: 754-kptj (`cross-branch-litmus-skew-gate`), filed in
  `plan/index.d/20260815t0545z-754-gate-skew-linux-mutable.yaml`

## What happened

The coordinator merged `origin/osx-next` and `origin/windows-next` into
`linux-next` (dedc40802, 29e9dec1b). Every branch was green on its OWN gates
before pushing — the platform pre-push gate is `./build.sh --check`, which does
not run litmus (the 748-tkjx blind spot). The first `./build.sh --ci-full` on
the merged union (run `local-ci-20260815T051005Z`, this host, as the
merge-to-main-and-release STEP 3 gate) failed **9 litmus steps + 1 rust test**.

Serial re-runs with an idle host confirmed 9 of 10 failures deterministic —
cross-branch semantic skew, not load:

| failing step | skew pair |
|---|---|
| litmus:cycle-flow-telemetry-shape STEP 6 | windows 682-epud authored `scripts/test-cycle-flow-emit-idempotency.sh` with mode 100644; litmus invokes it by bare path → Permission denied |
| litmus:release-gates-run-locally STEP 11 | windows added a 7th windows-only source; litmus pins the exact string `(6/6)` |
| litmus:plan-answer-envelope-citability STEP 16, litmus:methodology-path-query-citability STEP 20, litmus:expert-groundtruth-harness STEP 20 | windows 721-nyev resolution-by-execution vs the fixtures' `env -u TILLANDSIAS_PLAN_BIN` absence simulation — in a built checkout "absent" now resolves to the real target/release binary |
| litmus:macos-tray-diagnose-cli-surface STEP 4 | osx 735-2g5i moved the exit-code contract; the macos-specific pin greps the old location |
| litmus:capability-manifest-guard STEP 4 | union of both branches' subcommand additions vs the committed manifest, each side consistent alone |
| litmus:headless-init-status-check-source-built STEP 3, litmus:loop-status-fragment-overlay STEP 13 | overnight linux-next changes (headless main.rs ~319 lines; 752-pst5 loop-status paths) vs fixtures |

The 10th failure (`rust-tests`:
`a_prompt_podman_still_succeeds_under_the_same_budget`, killed at exactly its
30s budget) is the 638-ehzi parallel-contention class — see 754-3jht.

## The gap (what the packet closes)

1. **No litmus runs on the union until someone releases.** Platform branches
   gate with `--check`; the merged tree's first full litmus run happens inside
   the release path, where a red gate blocks a promotion the operator is
   waiting on. The coordinator's post-merge pass should run the litmus phases
   (or a targeted skew subset: suites whose pinned files changed since the
   merge base) BEFORE the release path needs them.
2. **`script-exec-bits` (731-d89b) does not scan litmus YAML `command:`
   fields.** `scripts/test-cycle-flow-emit-idempotency.sh` was invoked by bare
   path from a litmus step with mode 100644 and the checker reported
   `ok:script-exec-bits:26 checked` on the same tree. Extend the checker's
   invocation inventory to `openspec/litmus-tests/*.yaml` `command:` strings
   (bare `scripts/<name>.sh` occurrences not prefixed by `bash `/`. `/`source `).

## Evidence

- `target/convergence/check-logs.jsonl` run `local-ci-20260815T051005Z`
- Serial rerun transcript: 9 deterministic failures reproduced idle
- `git log -1 --format='%h %an %s' -- scripts/test-cycle-flow-emit-idempotency.sh`
  → 50ccc309d (windows, 682-epud), mode 100644 at merge
- `podman ps` 0.018s idle vs 30.001s killed under parallel litmus load
