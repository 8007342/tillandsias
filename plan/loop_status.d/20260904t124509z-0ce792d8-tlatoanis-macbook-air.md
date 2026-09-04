## Cycle 2026-09-04T12:45:09Z (tlatoanis-macbook-air — advance-work-from-plan)

Boundary first; `ok:gh-keyring-push-verified`; merge origin/linux-next BEFORE
the selector. Assigned work (997-e4v2 macOS half), not selector-drawn.

### STEP 1 OF 3 LANDED (a98ea0038). STEPS 2 AND 3 UNTOUCHED.
macos-tray stops consuming local projects over the control wire:
local_entry_to_menu, poll_local_projects_once, apply_local_projects, the
LocalProjectsPush/Reply arm, the initial-sync prime, the fallback tick poll, and
LocalProjects out of push_subscribe_topics. 114 passed (was 116, minus two tests
whose subjects are gone), clippy clean.

The topic pin is REPLACED, not deleted, and asserts the ABSENCE as well as the
remaining three — a pin checking only the three would pass on a list that had
quietly regained LocalProjects, and the tray would resubscribe to a topic whose
reader arm no longer exists and drop every frame silently. Mutation-controlled.

DELIBERATE DEVIATION FROM THE BRIEFED FILE LIST: menu_disabled_v2.rs untouched.
Its fixture drives host-shell's RENDERER, not a wire consumer; emptying it now
breaks the renderer test and couples step 1 to step 2. Split at the
wire-consumer boundary instead of the file boundary, so each step stays
independently green.

### THE MOUNT HALF IS BLOCKED, AND THE PINS WERE THE TRAP
vz.rs was handed to me as the mount half — delete the virtiofs fstab line, move
the two pins that go red. I did not, because on macOS that share carries TWO
independent payloads:

  vz.rs:692   home-src /home/forge/src virtiofs nofail 0 0   (the fstab line)
  vz.rs:725   STAGED="/home/forge/src/.tillandsias/guest-bin/tillandsias-headless"
  vz.rs:1021  home_src_dir().join(".tillandsias/guest-bin/tillandsias-headless")
  vz.rs:738   findmnt guard -> "staged_binary=unreachable reason=share-not-mounted"

The local projects 997-e4v2 removes, AND THE STAGED GUEST BINARY — how the macOS
host delivers tillandsias-headless into the VM. Observed live on this host
today: "[guest-binary] REFUSING to stage an OLDER guest binary ...
/Users/tlatoani/src/.tillandsias/guest-bin/...provenance.json".

The operator ruling is that an existing ~/src is ignored and left to rot AS A
PROJECT PATH. It says nothing about a staging directory living under the same
root. Deleting the fstab line removes guest-binary delivery on macOS.

BOTH PINS WOULD HAVE GONE RED, CORRECTLY, and the brief said to move them. They
are not stale here — they are load-bearing for a subsystem the packet does not
cover. Moving a pin because it went red is how a correct guard gets defeated,
which is the same class as this morning's stale-pin findings pointed the other
way round: there, a pin measured a file that had moved; here, a pin measures a
dependency that must not.

NOT MEASURED: whether WSL2 delivers its guest binary by the same route. yolanda
deleted a drvfs mount in slice 2 without hitting this, which means either a
different channel there or the same trap unnoticed. One grep on their side.

### CYCLE METRICS (`scripts/cycle-metrics.sh --cycle-start 2026-09-04T12:45:09Z`, verbatim)

```
experts: calls=0 answered=0 unsupported=0 degraded=0 errors=0 answer_rate=- tools=- source=absent
experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)
mcp: servers=0 plan-expert-calls=0 other-servers=uninstrumented-see-682-m8ek health=ok source=absent
expert_accuracy: pass=31 graded=33 total=33 rate=93% source=groundtruth-all-sets
flow: cycles=12 avg_completed_per_cycle=0.33 avg_commits_per_cycle=2.08 overhead_ratio=6.25 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-cycle-flow.jsonl
timing: steps=11148 build_check_ms_avg=139550 build_check_mix=mixed:forced=171,memoised=32 litmus_ms_avg=56364 slowest=litmus:codex-e2e-launch-parity:61000 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
repeat: window=since=2026-09-04T12:45:09Z steps=118 top3=build-preamble=2,build-check=1,build-check-memoized=1 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
recur: window=7d runs=10555 steps=178 top3=build-check:runs=161:total_ms=22966000:avg_ms=142645:fail_pct=32,step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=109:total_ms=3255000:avg_ms=29862:fail_pct=0,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=109:total_ms=2079000:avg_ms=19073:fail_pct=0 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
skippable: candidates=21 floor_ms=2000 min_runs=5 top3=step:checking-user-visible-terminology-against-the-dictionary-629-t6b:runs=109:avg_ms=29862:fail_pct=0:saved_ms_upper=3225138,step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea:runs=109:avg_ms=19073:fail_pct=0:saved_ms_upper=2059927,step:running-plan-ledger-tests-cargo-test-p-tillandsias-plan-all-targ:runs=109:avg_ms=13853:fail_pct=0:saved_ms_upper=1496147 source=/Users/tlatoani/claudia/tillandsias/.cache/metrics/tillandsias-timing.jsonl
plan: packets=687 ready=450 plan_bin=./target/release/tillandsias-plan
repo: commits_this_cycle=- worktree=clean traces=current
verdict: attention:experts-never-called
```

### NEXT
Steps 2-3 need the staging question answered first only for the vz.rs half; the
host-shell step (MenuState.local_projects, build_local_projects, the Local
submenu) is independent of it and is the next slice. The five wire variants
remain last.
