# Four meta-orchestration instant litmus tests are red on windows (3 step-budget timeouts + 1 seam logic)

- date: 2026-08-16
- host: windows (Yolanda, Git Bash / MSYS)
- discovered_by: windows meta-orchestration cycle 4, clean-tree run of
  `scripts/run-litmus-test.sh meta-orchestration --phase pre-build --size instant`
  at 781bb6e07 (post 770-f6u4/770-ifeg; none of the four touches files those
  changed — all four reproduce identically at the merged base)

## Failures

1. `litmus:e2e-eligibility-probe-shape` — STEP 4/7 "the probe emits exactly
   one well-formed verdict line" TIMEOUT at 5s. The probe passes standalone
   (`scripts/e2e-preflight.sh eligibility` → `eligible` in ~2s); the 5s step
   budget does not survive MSYS process-spawn pricing under the harness.
2. `litmus:meta-orchestration-dirty-tree-safety` — STEP 5/5 "canonical skills
   invalidate the forge image cache key" TIMEOUT at 10s. Same class.
3. `litmus:meta-orchestration-opsx-sync-merge` — STEP 4/5 "opsx sync-merge
   flows through the real guard without refusing" TIMEOUT at 10s. Same class.
4. `litmus:credential-channel-check-shape` — STEP 8/9 "forge with a
   mirror-resolved origin passes through the fixture seam" FAILS with
   `rc=1 out=missing:no-credential-channel` (expected the seam to yield the
   forge-mirror ok verdict). Not a timeout: the 756-2jnj fixture seam
   (linux-authored, commit b7850fadc) does not produce the mirror-authorized
   path on windows. Steps 6-7 (fail-closed directions) pass, so the guard
   fails SAFE here — the red is fixture fidelity, not a credential hole.

## Class

1-3 are the same platform tax measured in
`plan/issues/optimization/mcp-health-fixture-windows-spawn-tax-2026-08-16.md`
(~100x spawn cost): per-step `timeout_ms` values sized on linux. The
770-f6u4 change hit the identical wall in this same suite and sized its step
budget for the slowest host (30s → 180s) — the same treatment likely greens
1-3. Item 4 needs its fixture seam reproduced on windows by the 756-2jnj
owner (the seam's env/`git config` plumbing probably assumes a path shape or
a `gh`-less environment that differs here).

## Why it matters

The windows host cannot use this instant suite as a local gate while 4/15 of
it is ambient red — red-that-is-expected trains readers to ignore red
(672-4nts lesson). `./build.sh --check` does not currently run this suite, so
trunk safety is unaffected; the loss is local diagnostic power.

## Smallest next action

Resize the three step budgets for the slowest host (as 770-f6u4 did in the
same file family), and hand item 4's seam repro to the 756-2jnj owner with
the step-8 output above.

## Disposition (cycle 5, 2026-08-16)

- Items 1 and 3 RESIZED and expected green: eligibility step 4 5s -> 60s
  (probe passes standalone in <1s; the old budget priced only the skip
  branches), opsx-sync-merge step 4 10s -> 90s (fixture PASSES on windows in
  ~18s standalone, measured).
- Item 2 resized 10s -> 90s but stays RED on windows for a REAL reason the
  timeout was masking: test-hash-image-sources.sh is not windows-portable
  (autocrlf clone-hash divergence + fileMode=false voiding the chmod
  scenario). Spun off to plan/issues/
  hash-image-sources-fixture-windows-portability-2026-08-16.md — this is a
  fixture-portability defect, not a step-budget resize.
- Item 4 (credential-channel step 8 mirror seam) untouched, remains with the
  756-2jnj owner: the seam's fixture does not produce the forge-mirror
  authorized path on windows; step-8 output recorded above.
- Verification run (full meta-orchestration instant suite under the harness,
  post-resize): 12 PASS / 3 FAIL, up from 11/15. Items 1 and 3 GREEN at the
  new budgets. Remaining fails: the item-4 seam (expected), plus two NEW
  boundary-jitter timeouts the same class predicted — dirty-tree STEP 3
  (fixture measures 9.4s standalone vs its 10s budget; the SAME fixture
  passed at 10s in the opsx suite minutes later) and
  litmus:ledger-node-claim-shape STEP 2 (8 concurrent claimants measure 9.4s
  standalone vs an 8s budget — over budget even unloaded; green in cycle 4
  was luck). Resized in the same slice: dirty-tree step 3 10s -> 90s, step 4
  10s -> 60s (5.2s measured, inside sibling-step harness tax), opsx step 5
  10s -> 90s (same 9.4s fixture), claim step 2 8s -> 60s. Expected windows
  steady state after this slice: 13 PASS / 2 FAIL (item-2 fixture
  portability + item-4 seam), both owned elsewhere.

## Observation (cycle 10, 2026-08-17) — predicted steady state confirmed, plus ONE new red that DIRTIES THE CHECKOUT

Measured at 5e1905781 (windows/Yolanda, same suite/phase/size). Result was
**3 FAIL**, not the predicted 2. The two predicted reds reproduced exactly as
owned elsewhere:

- item 4 — `litmus:credential-channel-check-shape` STEP 8, `FAIL: rc=1
  out=missing:no-credential-channel`. ROOT CAUSE NOW NAMED: the fixture pins
  `env PATH=/usr/bin:/bin`, and on this host `git` is on neither
  (`env PATH=/usr/bin:/bin bash -c 'command -v git'` → not found). The seam is
  not "gh-less environment" sensitive — it simply has no `git` to run, so every
  probe branch falls through to the missing verdict. Hand this one line to the
  756-2jnj owner; it is a one-line fixture fix (add the host's git dir, or
  resolve git before restricting PATH), not an engine gap.
- item 2 — `litmus:meta-orchestration-dirty-tree-safety` STEP 5, now failing
  with the LOGIC message `FAIL: forge hash depends on checkout location`
  (no longer masked by the 10s timeout, as cycle 5 predicted). Stays with
  `hash-image-sources-fixture-windows-portability-2026-08-16.md`.

### NEW: `litmus:ledger-node-claim-shape` STEP 5 leaves `out.txt` in the repo root

STEP 5 ("every verdict line is well-formed against the grammar") TIMEOUT at
5s — the one step of that test cycle 5 did not resize (it resized STEP 2).
Two facts make this worth more than another budget line:

1. **The step's logic is correct.** Its own artifact, recovered from the
   checkout after the timeout, contains exactly the 5 well-formed lines it
   asserts: `claimed:a/b`, `in-flight:a/b`, `in-flight:a/b`, `released:a/b`,
   `free:a/b` → `tot=5 good=5`, which is a PASS. Only the 5000ms budget
   expired, mid-step, before the trailing `rm -f out.txt`.
2. **It writes into the checkout, not a temp dir.** The command does
   `... > out.txt 2>/dev/null` with the harness cwd at the repository root,
   then `rm -f out.txt` at the end. So the cleanup is on the success path
   only: any timeout or non-zero exit strands `out.txt` as an untracked file
   in the working tree.

That second half is a cross-host hazard, not a windows one. A stranded
`out.txt` is exactly the "status-visible untracked file" the
meta-orchestration startup boundary treats as sibling/operator work, so a
litmus run before a cycle's `snapshot` can hand that cycle a dirty-start
refusal, and a run after it can fail the Finalization `verify`. On linux the
step finishes fast, self-cleans, and nobody ever sees it; the defect is
latent everywhere and only *observable* where spawn cost is high. This cycle
hit it: the file appeared at 01:43 local during the suite run and had to be
removed by hand before the exit contract could be satisfied.

Fix shape (smallest verifiable slice): redirect the artifact into a
`mktemp -d` alongside the lease root the step already creates, so no path
inside the checkout is ever written — then the budget resize is a separate,
purely-cosmetic concern. A test that dirties the tree it is validating should
fail its own review, so the constraint worth pinning is "no litmus step
writes a relative path into the checkout", which is greppable.

Filed as its own packet rather than appended to the resize slice, because the
temp-dir fix is a correctness change with a different owner surface than the
windows step budgets.
