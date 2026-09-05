## Cycle 2026-09-04T23:05Z (macbookair-macos — 1029-5wvd closed, 1032-62rx + 1033-ev5r filed)

Direction: v0.5 stable-milestone. Landed on osx-next: ac41fc8c9 / f89886e9a
(1029-5wvd), a22b89569 (1032-62rx), 4a5434fb1 (1033-ev5r). Gate exit 0, 287s.

1029-5wvd — every ControlMessage discriminant pinned against literals MEASURED
by postcard encoding on the merged tree (2562769bb), coverage 19 of 32 -> 32 of
32. Rebased onto yolanda's collapsed enum once 54a9471a1 reached
origin/linux-next; their six independently measured points agree with my
encoding at every index. Three parses of declaration order also agree, which is
ONE MODEL CHECKED THREE TIMES and not evidence about the encoding.

TWO OF MY OWN GUARDS WERE BLIND AND THE SABOTAGE FOUND BOTH, not review.
Contiguity alone passed 64/64 against a trailing variant declared, pinned and
named but unsampled — 32 samples measuring 0..31 is contiguous whether or not a
33rd sits at index 32, and trailing is how this enum grows. The obvious repair,
a hand-maintained DECLARED_VARIANTS count, ALSO passed green because the count
and the sample list go stale TOGETHER. Generalised: A CHECK ASSEMBLED ONLY FROM
THINGS SOMEONE FORGOT TO UPDATE INHERITS THE OMISSION. Closed with a decoder
probe that asks the wire how many variants exist rather than asking a
remembered number.

PROCESS FINDING RATED ABOVE THE PIN: my first reorder mutation printed
"swapped" while its replace silently failed on non-adjacent declarations, and
the green that followed was indistinguishable from a blind guard. A SABOTAGE
ARM THAT NEVER APPLIED AND A GUARD THAT NEVER FIRES PRODUCE IDENTICAL OUTPUT.
Verify the mutation LANDED before its result means anything.

1032-62rx — ten wire-version refusal sites across six crates, six TAUTOLOGICAL
assertions (each compares a same-build peer's echo against the constant it
sent; set WIRE_VERSION to 9 and all six still pass), one tripwire, zero
mismatch tests. Owner yolanda. Everything in it is a source-read; criterion 3
is the sabotage it still owes.

1033-ev5r — the 977-448j gate refused an honest 'cargo test' closure, leaving
only a do-nothing scripts/ wrapper or a dishonest 'unscoreable:'. 994-8r3w
recurring in a second dialect: that packet extended the list and left the rule
implicit, so the list grew again. Stated the principle this time. CONFLICT
DISCLOSED — written by the author whose row it unblocked, hence the
negative-control arm rather than an accept arm alone. LANDED BUT NOT SETTLED:
macuahuitl ruled lenovinha reviews the widening as a second host.

TOOLING HAZARD, fleet-relevant, packet filed per macuahuitl: three refusals
arrived at exit code 0 today because the status read through a pipe is tail's.

Unreproduced, recorded as observations not diagnoses:
forge_agent_run_argv_exports_project_selection (997-e4v2); cli_unknown_flags +
exec_guest_stdin new-red twice under full-suite load, 2/2 and 2/2 green in
isolation — likely my own concurrent gates and ~50 orphaned waiter shells, NOT
proven.

experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=30 graded=33 total=33 rate=90% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=13016 build_check_ms_avg=149010 build_check_mix=mixed:forced=199,memoised=45 litmus_ms_avg=56364 slowest=step:running-workspace-tests-cargo-test-workspace-all-targets~span:134000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=3h steps=124 top3=build-preamble=23,build-check=19,step:checking-a-check-that-could-not-run-never-claims-what-it-would-h=8 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=12295 steps=185 top3=build-check:runs=186:total_ms=28501000:avg_ms=153231:fail_pct=34,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=122:total_ms=3636000:avg_ms=29803:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=122:total_ms=2221000:avg_ms=18204:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=22 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=122:avg_ms=29803:fail_pct=0:saved_ms_upper=3606197,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=122:avg_ms=18204:fail_pct=0:saved_ms_upper=2202796,step:checking-image-rebuild-keeps-the-installed-binary-s-launch-tag-7:runs=85:avg_ms=19858:fail_pct=0:saved_ms_upper=1668142 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=711 ready=455 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=clean traces=current
verdict: attention:experts-never-called
