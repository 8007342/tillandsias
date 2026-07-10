# build-install-and-smoke-test-e2e (Linux) — findings — 2026-07-10

- discovered_by: `/build-install-and-smoke-test-e2e` (linux_mutable, macuahuitl)
- agent: linux-macuahuitl-fable5-20260710T0009Z (meta-orchestration cycle)
- run_id: `20260710T003451Z`
- commit tested: `2bcced8e` (VERSION 0.3.260709.4 at preflight; ci-full bumped
  to 0.3.260710.x; HEAD advanced mid-run to `61abd3bf` via the sanctioned
  in-forge relay)
- evidence: `target/build-install-smoke-e2e/20260710T003451Z/01-build-install.log`

## Result: STOPPED at gate 1 (post-build e2e litmus inside `--ci-full`), exit 1

Everything before the post-build e2e suite was green: pre-build litmus
146/146, spec-binding coverage 100%, workspace build+tests, security suite
16/16, musl launcher built and installed
(`/home/tlatoani/.local/bin/tillandsias`, reports v0.3.260710.1, log lines
2391-2398). Post-build e2e suite: 5/6 — the sole failure is
`litmus:opencode-prompt-e2e-shape` STEP 6 (log lines 2445-2455). Per the
runbook the destructive gates (podman reset, pristine `--init`, forge lane)
were **not** reached; the host substrate was left intact.

## The order-255 fix is validated (STEP 4 + STEP 5 PASS live)

This run is the first `--ci-full` since STEP 5's unset-`$HEAD_BEFORE` fix
(order 255, commit `2bcced8e`): STEP 4 and STEP 5 both passed against a live
in-forge cycle through `scripts/litmus-git-delta-wait.sh` — order 255 exit
criterion 2 is discharged. The in-forge agent
demonstrably worked and pushed during the window: `origin/linux-next`
advanced `2bcced8e → 61abd3bf` (order 254 listen-vsock CI lane drain +
VERSION bump + trace sync), and its checkpoint swept this host's untracked
`plan/issues/integration-gate-feature-coverage-gap-2026-07-10.md` into
`fcdd56cb` (the forge operates on this checkout's worktree — known sanctioned
behavior).

## Analysis of the STEP 6 failure: wrong ref asserted (deterministic, was masked)

STEP 6 "verify remote branch HEAD advanced" failed with
`FAIL: remote HEAD unchanged (1684c111...) after 120s`. That sha is
**origin/main**: the recorder step and the probe both used
`git ls-remote origin HEAD`, and origin's HEAD symref tracks the default
branch (`ref: refs/heads/main`, verified with `git ls-remote --symref`). A
push to `linux-next` never moves origin HEAD, so the assertion is a
deterministic false negative on every non-default branch — the exact defect
class of STEP 5 (the assertion samples the wrong thing), and it was
invisible until now because the runner stops at the first failing step and
STEP 5 failed first on every prior run. Bug-behind-a-bug.

The push relay itself is healthy (see the `61abd3bf` evidence above), so
this is litmus infrastructure only — no product defect.

### Work Packet (→ plan/index.yaml order 262)

- id: `smoke-finding/opencode-prompt-e2e-step6-wrong-ref`
- repro: on a checkout of any branch whose name differs from origin's HEAD
  symref target, run `litmus:opencode-prompt-e2e-shape` with a working
  credential channel; observe steps 4-5 pass and step 6 fail while
  `git ls-remote origin refs/heads/<branch>` visibly advanced.
- fix (this cycle): `litmus-git-delta-wait.sh` remote-head mode probes
  `refs/heads/$(git rev-parse --abbrev-ref HEAD)`; the litmus recorder step
  records the same branch-scoped ref (+ `test -s` fail-loud when the branch
  has no remote counterpart); `litmus:git-delta-wait-shape` remote-head step
  upgraded to a regression pin (fixture pushes to a non-default branch while
  `ls-remote origin HEAD` resolves to nothing — old probe blind, new probe
  passes).
- verification: shape litmus 9/9 PASS post-fix; live single-litmus re-run
  recorded in the resolution below.

## Resolution (same cycle)

`litmus:opencode-prompt-e2e-shape` re-run standalone against the fixed
steps (fresh in-forge meta-orchestration cycle): see the order 262
completion event in `plan/index.yaml` for the verdict and evidence log
(`target/litmus-rerun-20260710/`). A full destructive e2e (gates 2-4) is
deliberately deferred to the next cycle: gate 1's red was litmus-infra-only,
the substrate is intact, and the fixed gate needs one clean pass before the
expensive destructive lane re-runs.

## Live re-run outcome (order 262 verification) + two more captures

The standalone re-run (`target/litmus-rerun-20260710/run.log`) reached STEP 3
and TIMED OUT at the 600s budget — steps 4-7 unreached, so the timeout is
unrelated to the order-262 fix. Cause: the in-forge cycle it launched
implemented the ENTIRE order 263 (git-mirror pre-receive YAML gate,
`e433b96f`: hook + Containerfile/entrypoint wiring + 10-step shape litmus)
— the meta-orchestration skill's in-forge greedy-drain doctrine structurally
fights STEP 3's fixed budget. Filed as **order 264** (bug+design, ready).

Order 262 itself is closed on composite evidence: shape-litmus regression
pin 9/9; steps 4-5 live PASS in run 20260710T003451Z; the fixed remote-head
probe executed live against the real origin push window
`129a85dd -> e433b96f` ("ok: remote HEAD advanced …", exit 0). The full
7-step standalone green now rides on order 264.

### Attribution addendum (capture)

`e433b96f` carries no `Generated-By:` trailers and its ledger `done` event
was stamped with the COORDINATOR's agent_id and a timestamp predating the
packet's filed event (copy-paste). Coordinator corrected the event
(author-date, forge host, untrailered note). The commit-attribution
discipline (order 53 / cheatsheet) is prose-only on the forge lane — same
enforcement-gap family as order 263; if it recurs, shape a pre-receive
trailer check rider onto the order-263 hook rather than a new mechanism.

### Coordinator audit of the in-forge order-263 work: PASS

`litmus:git-mirror-yaml-gate-shape` re-run on the coordinator host: PASS
(git-mirror-service suite 2/2). Ledger and bindings parse. Note the gate
binds when the git-mirror IMAGE is next rebuilt (`--init` / image build);
running mirrors are not retroactively gated.
