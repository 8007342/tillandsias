# build-install-and-smoke-test-e2e (Linux) — findings — 2026-07-09

- discovered_by: `/build-install-and-smoke-test-e2e` (linux_mutable, macuahuitl)
- agent: linux-macuahuitl-fable5-20260709T1923Z
- run_id: `20260709T195719Z`
- commit tested: `4c7babc3` (VERSION 0.3.260709.3 at preflight)
- evidence: `target/build-install-smoke-e2e/20260709T195719Z/01-build-install.log`

## Result: STOPPED at gate 1 (post-build status smoke inside `--ci-full`)

Compile, clippy, workspace tests, litmus pre-build, and install preparation all
passed. `./build.sh --ci-full --install` then failed in the post-build status
smoke: 4 PASS / 2 FAIL (88/88 spec coverage). Per the runbook the destructive
gates (podman reset, pristine `--init`, forge lane) were **not** reached and
**no reset was performed**.

Failing checks:

1. `litmus:opencode-prompt-e2e-shape` — STEP 5/7 "verify a plan/ file was
   updated" → `FAIL: no plan/ file modified in new commit(s)`.
2. `litmus:tray-parity-matrix-complete` — KNOWN failing; already tracked as
   order 243 (no new packet; ping event appended there).

## Analysis of failure 1: step-5 timing race (false negative)

STEP 3 launches a real in-forge meta-orchestration cycle (600s budget) against
this checkout; STEP 4 verified HEAD advanced. The in-forge agent
(linux-macuahuitl-bigpickle-20260709T2007Z) produced, during the smoke:

- `a68c9825` checkpoint: auto-generated artifacts + VERSION bump (→ .4)
- `ce70c788` feat(container_deps): order 252 (forge launch paths through the
  dependency model)
- `3621fc74` chore(plan): record order 252 completion in loop_status —
  **this commit touches plan/loop_status.md and plan/index.yaml**

So the "no plan/ file modified" verdict is contradicted by the commits that
exist on the branch: STEP 5 evaluated its commit window before the agent's
final plan-ledger commit landed/was visible. Same failure class as the race
partially fixed in `b0ccc88f` ("fix smoke test timing race") and the order-242
relaxation (`c40f80c1`): the check races the asynchronous tail of the in-forge
cycle it launched. Shaped as order 255.

### Work Packet (→ plan/index.yaml order 255)

- id: `smoke-finding/opencode-prompt-e2e-step5-race`
- repro: `./build.sh --ci-full` on a linux_mutable host with a credentialed
  in-forge agent; observe STEP 4 pass and STEP 5 fail while `git log`
  afterwards shows a plan/-touching commit from the in-forge cycle.
- next_action: make STEP 5 wait for the forge session's terminal state (or
  re-fetch and re-evaluate the commit range with a bounded retry window)
  instead of sampling immediately after STEP 4.

## Audit of the in-forge agent's order-252 work (passed)

Reviewed `ce70c788` as part of the operator-directed audit duty:

- `ensure_forge_launch` is invoked in the sync prelude of
  `ensure_enclave_for_project` (main.rs:7347), BEFORE any `block_on` — the
  order-176 "cannot call ensure_proxy_running inside block_on" constraint that
  justified the old inline proxy guard is respected by construction.
- Both entry points (tray `launch_forge_agent`, CLI
  `run_forge_agent_cli_mode`) route through `ensure_enclave_for_project`.
- The order-229 known-gap allowlist is eliminated; the source-audit test now
  asserts the full chain.
- New tests are fn-pointer typechecks (side-effect-free — consistent with the
  F1 hermetic-test fix from `plan/issues/linux-audit-recent-work-2026-07-09.md`).

No defects found; order 252's `completed` status stands.

## Standing blocker for linux local-build e2e acceptance

`litmus:tray-parity-matrix-complete` (order 243, ready, unclaimed) fails on
every `--ci-full`, so gate 1 of this skill cannot go green on Linux until 243
is fixed. Elevated: it gates ALL linux local-build e2e acceptance runs, not
just tray work.

## Resolution of failure 1 (2026-07-10, order 255 completed)

Root cause was deterministic, not (only) timing: STEP 5's inline command
referenced `$HEAD_BEFORE` without populating it. The litmus runner executes
each step in a fresh `bash -c` subshell (run-litmus-test.sh
execute-loop), so STEP 4's `HEAD_BEFORE=$(cat /tmp/opencode-e2e-head-before)`
never carried over; the empty expansion collapsed the range to
`HEAD..HEAD_AFTER` where both resolve to the same commit — an always-empty
diff and a guaranteed `FAIL: no plan/ file modified` on every run since the
step's introduction (a6a211a7). The "(no diff)" diagnostic in the recorded
output is consistent with this; the commits observed on the branch afterwards
were never the thing being compared.

Fix (linux-macuahuitl-fable5-20260710T0009Z):

- `scripts/litmus-git-delta-wait.sh` — shared bounded-retry git-delta probe
  (modes local-head / plan-commit / remote-head; reads the before-sha from
  the recorded file, immediate first probe, 5s poll, 120s window, verdict
  grammar `^(ok: .*|FAIL: .*)$`, exit 0/1/2). The retry window also covers
  the genuine async half of the original diagnosis (git-mirror relay lag)
  for all three post-forge assertion steps, not just STEP 5.
- `litmus-opencode-prompt-e2e-shape.yaml` steps 4-6 now invoke the helper
  (timeout_ms 150000 > the 120s window, so a genuine miss reports FAIL, not
  runner TIMEOUT).
- New `litmus:git-delta-wait-shape` (9 steps: warm pass, bounded fail-loud,
  mid-window re-sample, no-dead-check negative, before-file exit-2 guard,
  remote-head ls-remote path, e2e wiring) registered under meta-orchestration
  in litmus-bindings.yaml; instant pre-build suite 4/4 PASS.

Exit criterion 2 (a real `--ci-full` in-forge cycle passing STEP 5
deterministically) is expected to be discharged by the next post-build e2e
gate; if that gate still reds on STEP 5, reopen order 255 with the new
helper's diagnostic block attached.
