# Two pre-existing litmus reds in forge-environment-discoverability on windows (2026-08-16)

Filed by the windows meta-orchestration cycle (16:20 local, 2026-08-16) after a
scoped run of `scripts/run-litmus-test.sh forge-environment-discoverability
--phase pre-build --size instant --compact` for the 781-6gys work.

## Attribution evidence

Both tests fail IDENTICALLY on a pristine worktree at HEAD `9a677a116` (no
local changes), so they are host reds, not regressions from the 781-6gys diff:

1. `litmus:expert-refresh-cargo-target-shape` STEP 2 — "fake cargo fixture
   with custom CARGO_TARGET_DIR installs built binary and logs success" fails
   with `FAIL: content= log_success=0`. The visible noise is git CRLF
   conversion warnings on the fixture files (`scripts/hooks/post-commit`,
   `crates/tillandsias-plan/src.rs` inside the fixture), which points at the
   Windows autocrlf mangling the fixture's fake-cargo script or the content
   comparison (`content=` is EMPTY — the installed fixture binary's content
   was not read back intact). The test passed on linux forge when it landed
   (plan/loop_status.md:5453-5458, cycle 2026-07-31T02:00Z).
2. `litmus:project-answer-synthesis-refusal-typed` STEP 3 — "generic lane,
   DEAD endpoint, synthesis question -> missing_capability=local-inference"
   produces EMPTY output on this host (expected the typed refusal). Same
   family as the known windows litmus platform-tax reds
   (plan/issues/windows-red-meta-orchestration-litmus-2026-08-16.md), but
   these two are not recorded anywhere — they would have stayed invisible.

## Why this matters

`forge-environment-discoverability` is the spec that guards the expert build
path this host just changed (781-6gys artifact cache). A spec suite that is
red-by-default on windows trains agents to read "3 FAIL" as noise, which is
exactly how a real regression hides (the 637-df4z lesson).

## Smallest next action

Reproduce each step's command in isolation under Git Bash, determine whether
the red is (a) CRLF fixture corruption — fix the fixture to write with
`core.autocrlf=false` or normalize, or (b) a real engine gap on windows —
then either fix the fixture host-awareness or file the engine defect.
Tracked as plan packet order `782-ih74`.
