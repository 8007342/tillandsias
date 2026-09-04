## Cycle 2026-09-04T12:11:37Z (tlatoanis-macbook-air — advance-work-from-plan)

Boundary first; credential preflight `ok:gh-keyring-push-verified` (982-sguu);
`git merge origin/linux-next` BEFORE the selector, per the ordering ruled in
after last cycle's stale-ledger claim. Direction *forge agents local EXPERTS*.

### WORK: 1006-jfwv (b94e08e74, completed) — a release blocker
980-xcaf committed a 448 KB `mixed-clusters.qcow2` and
litmus:no-tracked-binaries-shape has been red on every branch since, unseen for
a day because `./build.sh --check` runs no litmus (748-tkjx).

PRE-FIX PER CRITERION, measured before the diff:
  C1 tracked at 458,752 bytes, five tests passing   -> generated, 5 pass
  C2 EXIT=1 blocked:tracked-binaries:<the fixture>  -> EXIT=0, ok: 38/38
  C3 n/a unless a tracked fixture is required       -> not required, none added
C3 is the escape hatch and it going UNUSED is the good outcome; recorded rather
than quietly skipped.

### I WAS WRONG ABOUT THE TRADE-OFF, AND AN ARM I NEARLY CUT CAUGHT IT
I wrote the generator expecting to LOSE qemu's independent opinion: the old
whole-image assertion compared a SHA-256 captured once from `qemu-img convert`,
and a self-generated fixture only round-trips our own understanding of qcow2. I
documented that as the honest cost of removing the binary.

The opportunistic cross-check arm then failed on its first run:

  qemu-img: Could not open '...mixed-clusters.qcow2':
            Image does not contain a reference count table

This reader IGNORES REFCOUNTS — it only expands — so it accepted a file qemu
considers structurally invalid, and all five tests agreed with it. With a
refcount table and block added the image is valid and qemu's expansion matches
`expected_raw()` byte for byte.

SO THE CROSS-CHECK IS NOT LOST, IT IS STRONGER: it used to be a constant from
one host on one day; it is now re-derived on every run wherever qemu-img exists.
The generalisable rule, now in the module header: A GENERATOR VALIDATED ONLY
AGAINST THE READER IT FEEDS PROVES THE TWO AGREE, NOT THAT EITHER IS RIGHT.
That is today's recurring shape — correct-looking output, wrong target — in its
hardest form, because there was no disagreement anywhere to notice.

### FOR ANYONE VERIFYING THIS
`check-no-tracked-binaries.sh` scans `git diff --numstat <empty-tree> HEAD`, so
it reads HEAD, not the index. It stays red between `git rm --cached` and the
commit, which reads as "the fix did not work" to anyone checking in between.

### CYCLE METRICS (`scripts/cycle-metrics.sh --cycle-start 2026-09-04T12:11:37Z`, verbatim)

```
experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=31 graded=33 total=33 rate=93% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=11013 build_check_ms_avg=139165 build_check_mix=mixed:forced=170,memoised=29 litmus_ms_avg=60900 slowest=litmus:codex-e2e-launch-parity:61000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=since=2026-09-04T12:11:37Z steps=129 top3=build-check=2,build-preamble=2,step:checking-a-check-that-could-not-run-never-claims-what-it-would-h=2 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=10420 steps=167 top3=build-check:runs=160:total_ms=22761000:avg_ms=142256:fail_pct=33,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=108:total_ms=3226000:avg_ms=29870:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=108:total_ms=2062000:avg_ms=19092:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=21 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=108:avg_ms=29870:fail_pct=0:saved_ms_upper=3196130,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=108:avg_ms=19092:fail_pct=0:saved_ms_upper=2042908,step:running-plan-ledger-tests-cargo-test-p-tillandsias-plan-all-targ:runs=108:avg_ms=13888:fail_pct=0:saved_ms_upper=1486112 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=686 ready=449 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=clean traces=current
verdict: attention:experts-never-called
```

`build-check fail_pct=33` over 160 runs, unchanged from last cycle; no failures
were mine this time. The three `skippable:` candidates are unchanged at
`fail_pct=0` over 108 runs — this host's top one is the terminology dictionary
check (629-t6b), which is the agreement 1008-85ry wanted a second host for
(lenovinha being the first). `repo: commits_this_cycle=-` still unpopulated with
`--cycle-start` supplied (noted on 1001-q3zf).

### STILL DEGRADED ON THIS HOST
`scripts/run-litmus-test.sh` prints `warn:litmus-degraded-no-yq` even when
/opt/homebrew/bin is prepended to PATH before the call, so the runner is not
simply inheriting it. yq IS installed at /opt/homebrew/bin/yq. Noted on
macneo's host-tools resolution packet as the same class one tool over.

### NEXT
997-e4v2's macOS half was this window's FALLBACK, not its primary — the
coordinator assigned 1006-jfwv as a release blocker. Step 1 has not started;
steps 2 and 3 are untouched and the five wire variants remain in place.
