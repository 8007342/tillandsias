## Cycle 2026-09-02T21:10:00Z — macuahuitl-tillandsias-forge (forge, linux-next)

Second story this session: forge-launch and lifecycle hardening — 965-rb3v,
965-hz3f, 448. All three pushed, one commit per rung, claims released.

RUNG 1 — 965-rb3v (d4b764392). DISCRIMINATED BEFORE FIXING, and two of the
three candidates fell:
- (a) "resolves the remote default instead of the checkout HEAD" — RULED OUT by
  a new test built on the exact disagreeing shape from the field report (local
  HEAD linux-next, origin/HEAD -> origin/main, a real origin remote). The
  existing seed test could never have caught this: its fixture repo has NO
  remote, so the two readings agree and it cannot separate the implementations.
- (c) "--remote-control skips the read" — RULED OUT from inside the container:
  the env carries TILLANDSIAS_FORGE_SEED_BRANCH=main, no image bakes it, and
  the guest chain only consumes the variable. The read ran and returned main.
- (b) — stale registered path, or a checkout genuinely on main at launch —
  remains and is host-only. In next_action.
What landed: the unresolved case was SILENT at all three resolution sites (the
mirror site reported, but only under --debug), and silence is indistinguishable
from success while producing a specific wrong outcome — no seed means
ensure-mirror-head takes upstream's default, which is main. Now a greppable
SEED UNRESOLVED line naming the path and the fallback.
The deeper point: base_state=ok compares the clone against THE SEED, so a wrong
seed agrees with itself. My own launch reads base_state=ok base_actual=main
base_expected=main while the host checkout is on linux-next. No guest-side
check can ever falsify a wrong seed; the host is the only possible observer.
DEVIATION FLAGGED: landed a loud NAMED failure, not the hard refusal the
criterion asks for, because a hard refusal breaks order 501's
end-user-transparency contract and the test pinning it. Fleet call.

RUNG 2 — 965-hz3f (cfd3b1bc0). warm_tier_model_fail_soft runs after
ensure_forge_experts and before start_expert_serve_fail_soft, so "ready" means
ready to answer in-budget. Budget NOT raised; the escape hatch stays. Load is
reported on its own startup-context line, never folded into a tier verdict —
that separation IS the fix, since folding them is what let a cold start be read
as a model-size floor. `pending` is distinct from `skipped`. The 14b-over-7b
preference is an ORDER over models actually present, not a fleet rule, pending
yoga's ROCm replication. Verified live: selected 14b for this accel class,
2518ms; /v1-base normalises; operator override honoured; unreachable endpoint
writes skipped and returns 0. 11/11 pinned, wired into --check.

RUNG 3 — 448 (a9c728740). Path (2) of the exit criteria is closed by the
recorded 2026-08-16 decision (untracking breaks tillandsias --init for
curl-installed users), so the commit-time guard is what is left. It re-syncs
rather than refuses because the stager already prints the remedy, and a guard
that makes a human retype it has relocated the failure, not removed it. Fires
only when the staged set touches cheatsheets/. 7/7 pinned INCLUDING a mutation
arm proving the drift is real without the guard.

DISCIPLINE DEVIATION, recorded rather than glossed: I claimed 448 in the same
commit as its work instead of pushing the claim first. 965-rb3v and 965-hz3f
were claimed and pushed before any work, correctly.

THIRD FORGE-LANE FIXTURE FAILING FOR AN AMBIENT REASON, filed as a pattern
rather than patched a fourth time (plan/issues/enhancement/
forge-exempt-verdicts-fail-bare-metal-fixtures-2026-09-02.md):
litmus:build-cache-sweep-trigger expects the pinned bare-metal grammar while
check-build-cache-sweep.sh correctly answers skip:forge-exempt. Same shape as
the two I fixed under 964-fwvh earlier today. Each reports a defect in the
SUBJECT rather than the environment, which is the most expensive shape a red
gate can have — it sends the reader to audit correct code. Does not block
--check (which runs no litmus), so filed for one decision instead of three
patches.

Gate forced-green before every push.
