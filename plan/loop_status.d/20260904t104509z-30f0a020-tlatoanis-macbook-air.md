## Cycle 2026-09-04T10:45:09Z (tlatoanis-macbook-air — advance-work-from-plan)

Boundary snapshot taken FIRST this cycle. Selector seed `tlatoanis-macbook-air`;
Direction *forge agents local EXPERTS*. `--host tlatoanis-macbook-air` in both
namespaces now (packet events and this stem), per the coordinator's correction —
my previous entry landed under `macos` and read to the audit as a second host.

### WORK: 1004-8vkv (a601c58e0, completed)
`loop-status-append` dropped a bare path argument, fell through to stdin, and
then behaved differently depending on what fd 0 was: an inherited socket blocked
forever (lenovinha: 26 minutes at 0.0% CPU), a closed stdin reported "fragment
carries no `## Cycle` section" — a confident statement about a file never opened.

Fixture first and RED first at 3/6, the hang reproduced as an exit-124 timeout
kill. Positional now honoured when it resolves to a file; stdin read on a thread
with a 5s deadline rather than predicted from descriptor kind (a FIFO is a
"pipe" and blocks exactly like a socket, so the fd type answers the wrong
question); empty read says `read 0 bytes`; the no-Cycle refusal names byte count
and first line. litmus:loop-status-append-input-shape bound. Three skills
updated — advance-work-from-plan:488 CORRECTED rather than extended, because its
warning had landed at HEAD and this change made it false.

### FOUR THINGS I GOT WRONG, all caught, all the same shape
1. MY FIXTURE'S ARM 2 TESTED NOTHING. It supplied a positional AND a blocking
   stdin, so once the positional worked it passed without reading fd 0 — green
   while measuring nothing. Corrected, with the reason in the file.
2. I MISREPORTED litmus:plan-only-push-lane-shape as pre-existing on the
   strength of stash-and-rerun. That proves only it is not in the WORKING TREE;
   I had a committed build.sh edit from this morning a stash cannot see. Redone
   by attribution (the fixture copies four scripts and never reads build.sh;
   `git log --since=2026-09-04` over all five is empty; newest b300d6b92
   predates my work). Routed to the coordinator, now filed as a p2 linux packet.
3. I CLAIMED A GATE FAILURE "ARRIVED WITH THE INTEGRATION". It did not. It was
   in my own tree: I appended a `completed` EVENT while `set-field` refused the
   status flip for missing `--evidence` (650-dq6u), so the packet folded as
   `in_progress` with a terminal event attached. `violation:fragment-status-loss`
   caught it, and its wording is the lesson: "Nothing was discarded, so nothing
   looks wrong — the packet just stays claimable forever."
4. TWO GATE RUNS LOST to improvising on a clippy suggestion instead of applying
   it verbatim (`&args` -> `&args[..]` -> `args`, which is what it said first).

The common cause of 2, 3 and 4 is reading a FILTERED view instead of the actual
verdict — a grep for `fail` matched `12 passed, 0 failed` and hid the real
`EXIT=1`. `./build.sh --check > log; echo $?` answered in one run what three
greps had obscured.

### PROCESS
The selector ran BEFORE I merged origin/linux-next and offered 1001-q3zf, which
macuahuitl had already closed in f9eb79059. I claimed a completed packet, caught
it on the post-merge fold, and dropped the unpushed claim. ON A PLATFORM HOST THE
SELECTOR MUST RUN AFTER THE TRUNK MERGE, not after the platform-branch pull
alone; re-running it post-merge returned a different top pick.

### CYCLE METRICS (`scripts/cycle-metrics.sh --cycle-start 2026-09-04T10:45:09Z`, verbatim)

```
experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=31 graded=33 total=33 rate=93% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=10763 build_check_ms_avg=138071 build_check_mix=mixed:forced=168,memoised=27 litmus_ms_avg=65667 slowest=litmus:codex-e2e-launch-parity:61000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=since=2026-09-04T10:45:09Z steps=138 top3=build-check=10,build-preamble=10,litmus-suite=3 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=10170 steps=167 top3=build-check:runs=158:total_ms=22299000:avg_ms=141132:fail_pct=33,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=106:total_ms=3168000:avg_ms=29886:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=106:total_ms=2029000:avg_ms=19141:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=22 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=106:avg_ms=29886:fail_pct=0:saved_ms_upper=3138114,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=106:avg_ms=19141:fail_pct=0:saved_ms_upper=2009859,step:running-plan-ledger-tests-cargo-test-p-tillandsias-plan-all-targ:runs=106:avg_ms=13962:fail_pct=0:saved_ms_upper=1466038 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=682 ready=448 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=clean traces=current
verdict: attention:experts-never-called
```

`build-check fail_pct=33` is up from 30 this morning over 158 runs, and three of
this cycle's failures were mine. The three `skippable:` candidates are unchanged
and still `fail_pct=0` over 106 runs. `repo: commits_this_cycle=-` remains
unpopulated even with `--cycle-start` on a cycle with three commits (noted on
1001-q3zf). `verdict: attention:experts-never-called` is accurate: one
`plan_answer` for the Direction, no expert-serve.

### NEXT
997-e4v2 macOS half at 12:15, sequenced per yolanda: macos-tray consumers, then
host-shell, and the five wire variants LAST — untouched if I do not reach them,
and I will say which steps I completed rather than "the macOS half is done".
