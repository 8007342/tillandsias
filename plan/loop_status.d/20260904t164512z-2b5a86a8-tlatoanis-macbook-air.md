## Cycle 2026-09-04T16:45:12Z (tlatoanis-macbook-air — advance-work-from-plan)

Boundary first; `ok:gh-keyring-push-verified`; merge origin/linux-next before
the selector. Assigned scope: 1019-ivia ONLY — tray/mod.rs untouched, no wire
work, per the coordinator's 16:15Z ruling.

### 1019-ivia IMPLEMENTED (14f1aaa5b, verified upstream)
Guest-binary staging moves off the `home-src` share so 997-e4v2 can retire it
without silently removing binary delivery on macOS — fetch-headless.sh FALLS
BACK to a pinned download rather than failing, so the symptom would have been a
guest quietly running an older headless.

`tillandsias_core::guest_bin_path` declares the host dir, guest mount, share tag
and binary path ONCE; writer and all readers call in here, so they cannot drift
the way the CA path did before 998-qrwu. A new READ-ONLY `guest-bin` virtio-fs
share carries it, created before config validation like model-cache, non-fatal
with a warning naming the consequence.

NOT `config::state_dir()`: that is ~/Library/Logs/tillandsias on macOS, and a
staged executable is not a log. `$HOME/.local/state/tillandsias` is the root
998-3z6g MEASURED for surviving the VM boundary, so this follows that decision
instead of inventing a second answer.

### CRITERIA, WITH PRE-FIX RESULTS
  C1 staging under ~/src            FAILED -> derives from the state dir
  C2 live mutation control          FAILED -> STILL FAILED, not attempted
  C3 pins state their purpose       FAILED -> both now do
  C4 dependency recorded            FAILED -> recorded

C1's "and on Windows" is VACUOUS and I checked rather than assumed: Windows
embeds the binary via include_bytes! from a BUILD-time contract; there is no
runtime staging directory to relocate.

C2 IS THE ONE THAT PROVES DELIVERY SURVIVES and it is not done — it needs a
rebuilt tray and a booted VM (this host's bundle is 2026-08-30). Until it
passes, 997-e4v2's vz.rs half should NOT land on this packet's strength: the
dependency is satisfied in SOURCE, not in EVIDENCE.

### THE RULE I ADOPTED THIS MORNING, USED
`cargo check -p tillandsias-headless --features tray` before landing. It is RED
— E0531/E0425/E0560, all `local_projects`, all the known 997-e4v2 step-2 break
that yoga's slice fixes. This change touches none of those files. The value was
not catching a new break; it was being able to ATTRIBUTE an existing one instead
of guessing.

### PROCESS, HONESTLY
The edit path was untidy: a misplaced awk insertion put a shell block at the top
of vz.rs and I compounded it with an off-by-one deletion. Recovered, and
`git diff --stat` afterwards is what confirmed the landed state is confined to
four files with no residue. Worth doing PRECISELY because the route there was
messy — a clean diff is the only evidence that a messy edit ended up correct.

### CYCLE METRICS (`scripts/cycle-metrics.sh --cycle-start 2026-09-04T16:45:12Z`, verbatim)

```
experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=30 graded=33 total=33 rate=90% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=11643 build_check_ms_avg=142426 build_check_mix=mixed:forced=176,memoised=38 litmus_ms_avg=56364 slowest=step:running-workspace-tests-cargo-test-workspace-all-targets~span:134000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=since=2026-09-04T16:45:12Z steps=122 top3=build-preamble=2,build-check=1,build-check-memoized=1 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=11050 steps=182 top3=build-check:runs=166:total_ms=24170000:avg_ms=145602:fail_pct=32,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=113:total_ms=3371000:avg_ms=29831:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=113:total_ms=2134000:avg_ms=18884:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=21 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=113:avg_ms=29831:fail_pct=0:saved_ms_upper=3341169,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=113:avg_ms=18884:fail_pct=0:saved_ms_upper=2115116,step:running-plan-ledger-tests-cargo-test-p-tillandsias-plan-all-targ:runs=109:avg_ms=13853:fail_pct=0:saved_ms_upper=1496147 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=700 ready=455 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=dirty traces=current
verdict: attention:worktree-dirty
```

### NEXT
997-e4v2 step 3 at 19:45Z after the Linux half lands and osx-next merges at
18:41Z: my consumers including the tray/mod.rs:1426 handler, then yolanda's
windows-tray collapse, then the five wire variants with WIRE_VERSION 3.
There is NO prepared wire commit; it gets written fresh against the post-merge
tree.
