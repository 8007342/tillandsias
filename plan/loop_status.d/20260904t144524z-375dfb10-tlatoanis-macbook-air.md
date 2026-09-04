## Cycle 2026-09-04T14:45:24Z (tlatoanis-macbook-air — advance-work-from-plan)

Boundary first; credential preflight `ok:gh-keyring-push-verified-refstate-refused`
(a stale-branch verdict, not a credential fault — its own text says so and names
the ff-only remedy); merge origin/linux-next before the selector.

### STEP 2 OF 3 LANDED (53fa82ad2, verified upstream). STEP 3 UNTOUCHED.
MenuState.local_projects, both id constants, build_local_projects and its render
call are gone. The Linux-parity contract drops from SIX top-level items to FIVE
— status, cloud-projects, separator, version, quit — which is product-visible
and is recorded in three parity tests rather than absorbed silently.

Tests were UPDATED, not deleted, where the property survived: the per-project
gating tests used local projects only as a vehicle to reach a project submenu,
and that property now lives on the cloud path. Exactly one test was deleted
outright, because its subject no longer exists.

### TWO FAILURES THE TOOLING CAUGHT, BOTH GENERALISABLE
1. INDEX-BASED LOOKUPS BROKE. Tests reached cloud as `&items[2]`; with local
   removed, index 2 silently became a different node, so they failed on a menu
   CHANGE rather than a menu DEFECT — a positional assertion cannot distinguish
   those. Converted to id-based lookup. This is the anchor-window class in a new
   costume: an assertion that identifies its subject by POSITION rather than by
   NAME goes wrong quietly whenever the structure around it moves.
2. CLIPPY CAUGHT A VESTIGE OF MY OWN EDIT. Narrowing
   `for gated in [LOCAL, CLOUD]` to one element left three degenerate loops.
   `cargo test` was green on all three; the gate's clippy was not. A
   search-and-replace that NARROWS a collection leaves the old collection's
   shape behind, and the test suite has no opinion about that.

### DELIBERATELY KEPT FOR STEP 3
ProjectScope::Local in menu_action.rs. Unreachable from the menu now, but
removing it changes shared action ROUTING mid-sequence — the sequence whose
whole point is that the shared surface changes last — and a click can still
arrive from a pre-change menu. Same reasoning as the neighbouring reset-guest
case. The test asserts the LITERAL legacy id resolves Inert, since the constant
is gone.

### CROSS-HOST EDIT, DECLARED
windows-tray/tests/portable_smoke.rs — a sibling's file. It is portable BY
DESIGN (its header: "tests that run on the Linux dev box ... menu state
interop"), compiles and runs here, and broke MY gate rather than only Windows
CI. Verified, not blind. Nothing Windows-specific touched.

### EVIDENCE ORDERING (1024-c3h3), FIRST CYCLE APPLYING IT
Landed first, cited the landed sha, and verified it:
`git merge-base --is-ancestor 53fa82ad2 origin/osx-next` -> UPSTREAM. Worth
noting this land printed NO "MERGING" line, so it took the rebase branch — the
exact path that produces ghosts. Deriving the sha before landing, as I did last
cycle, would have been unsafe here rather than merely lucky.

### CYCLE METRICS (`scripts/cycle-metrics.sh --cycle-start 2026-09-04T14:45:24Z`, verbatim)

```
experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=30 graded=33 total=33 rate=90% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=11396 build_check_ms_avg=140603 build_check_mix=mixed:forced=174,memoised=35 litmus_ms_avg=56364 slowest=step:running-workspace-tests-cargo-test-workspace-all-targets~span:134000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=since=2026-09-04T14:45:24Z steps=121 top3=build-preamble=4,build-check=3,step:checking-a-check-that-could-not-run-never-claims-what-it-would-h=2 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=10803 steps=182 top3=build-check:runs=164:total_ms=23568000:avg_ms=143707:fail_pct=32,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=111:total_ms=3313000:avg_ms=29846:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=111:total_ms=2097000:avg_ms=18891:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=21 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=111:avg_ms=29846:fail_pct=0:saved_ms_upper=3283154,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=111:avg_ms=18891:fail_pct=0:saved_ms_upper=2078109,step:running-plan-ledger-tests-cargo-test-p-tillandsias-plan-all-targ:runs=109:avg_ms=13853:fail_pct=0:saved_ms_upper=1496147 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=696 ready=453 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=dirty traces=current
verdict: attention:worktree-dirty
```

`worktree-dirty` in that capture is this entry's own uncommitted fragments;
the tree was clean at land.

### REMAINING ON 997-e4v2
Step 3: the five wire variants + headless side + ProjectScope::Local + the
Windows topic-list collapse and fallback retry, ALL IN ONE COMMIT. And the
vz.rs mount half, blocked on 1019-ivia until guest-binary staging moves off
~/src.
