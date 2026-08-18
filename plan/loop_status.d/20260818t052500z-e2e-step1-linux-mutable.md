## Cycle 2026-08-18T03:36Z — the destructive e2e attempted twice; six gate failures fixed, and the real blocker is now named on both paths

**Result: the substrate was NOT destroyed, correctly, both times. Step 1's gate
went from six failures to one, and that one is a credential — on the full lane
legitimately, and on the smoke lane wrongly.**

- **Priority (1) — 518**: already `completed`. Re-confirmed in situ this cycle
  (model cache 1.5 GB before and after a post-build run that executed
  litmus:inference-deferred-model-pulls for 92s; scratch dir at
  /tmp/tillandsias-litmus-deferred-pulls, emptied by the cleanup step). **This
  is confirmation, not discovery — 808-zrzz proved it at 15:38 today by the
  same command, twice.** The XDG half the operator named was NOT resolved by
  the 518 fix, which gave the litmus a scratch dir and sidestepped it; filed
  **815-gdjk**.

- **Priority (2) — the destructive e2e did not run, and the runbook is why.**
  Step 1 exited 1 on both attempts, and the runbook forbids reaching §2/§3
  after that. Worth stating plainly: the notification channel reported
  "exit code 0" for all three background builds; the recorded `echo $?` said 1
  every time. Reading the pipeline's status as the producer's would have had me
  wipe the image store on a failed gate.

- **Six gate failures, all introduced tonight, none the standing class they
  looked like.** Five mine, one the 797-p2xa fork's.
  - **816-kq2z** (closed): the three `fragment-*` subcommands parse ONE file
    and never read the ledger, but sat behind `Ledger::load_with_fragments`.
    Measured: `capabilities` 1ms (returns before the load) vs
    `fragment-terminal-events` 133ms. The guard calls all three per fragment —
    3 x 102 x 132ms ~= 40s wasted on EVERY build, on every host. Now 1ms each,
    guard 41s -> 1s, verdict byte-identical. **Whole-gate time this cycle:
    13s, down from 46-49s.**
  - That cost crossed a 30s litmus step budget when my 797-qm4t and 812-d45t
    channels landed, so the symptom was a TIMEOUT — and `--check` has no
    per-phase budget, so it printed "41.0s" and stayed green. I read that
    number twice without noticing it had changed.
  - Fixing the timeout **unmasked a second failure it had hidden**: step 7
    captured `2>&1` then prefix-matched, silently requiring the guard's stderr
    to be empty. Now reads both channels separately, still reading stderr
    because the stale-binary skip note lives there.
  - **Four more from one mis-sorted line.** I put
    `fragment-misplaced-definitions` above `fragment-event-packets` in
    capabilities.txt and reported "crate tests 176 pass" in the 812-d45t
    closure — that was the LIB suite; the BIN suite was red. Four
    forge-environment litmus tests end with "the crate's own unit pins are
    GREEN" and all four failed on it. **No gate runs that test directly**
    (`--ci-full` never executed it), so only the indirect signal fired, four
    times, pointing away from the cause.
  - The fork's: `localhost/tillandsias-git:latest` as a MOCK ARGUMENT. Pulls
    nothing, but check-container-bases.sh greps scripts/ and cannot tell an
    argument from a reference. `--check` doesn't run that policy, `--ci-full`
    does — which is how it reached linux-next green.
  - **Correction to the fork's report**: it called these "five reds, identical
    in both runs", reasonably read as pre-existing. Both its runs were AFTER my
    changes landed. A red stable across two runs is not thereby old.

- **817-8czp** (closed): the forge lane reported "provider likely exited
  between tool calls". The provider did not exit. The cycle ran (experts 22/22,
  mcp ok), hit the credential guard, and refused — and the exit contract
  *requires* a blocked cycle that cannot push to emit no marker. So the one
  state where a missing marker is CORRECT was described as a crash, pointing at
  the only healthy link while the log named the fault in full. Complements
  808-zrzz rather than repeating it: that run reached the push and got the
  correct `push-failed-upstream-auth-stale`; this one refused earlier, the path
  with no diagnosis. The fixture's pass line was a hardcoded "12/12" that would
  have said 12/12 forever; now 14/14 with a discriminating pair and a prose
  control.

- **818-cgpn** (implemented, NOT completed): with FULL blocked, the limiter
  chose SMOKE — and smoke failed on the same credential. Every surface smoke
  verifies was green (branch, expert base, experts healthy, `build.sh --check`
  PASS 89s); it returned `MO-SMOKE: FAIL credential channel blocked`. Smoke is
  verify-only and pushes nothing, so a PUSH credential cannot harm it. Gating
  it there means both paths fail together and there is no path — and that takes
  §2/§3 down with them, which never touch a credential. Skill rule 3a now makes
  the guard a report in smoke mode. Held at `implemented` because the
  deliverable wants a live forge smoke lane returning PASS while auth is stale,
  and no in-forge agent has run under the amended text.

- **808-zrzz gains a second link and an invisible dependency.** Its
  series-wiring observation is now measured on both lanes, and which lane you
  get depends on `forge-e2e-rate-limit.sh` state — i.e. on how recently a full
  forge cycle ran. That dependency was invisible while both outcomes failed.

- **FOR THE OPERATOR**: **809-w2xy** remains the root blocker and only you can
  clear it — the mirror's upstream-auth verdict was 21504s then 22880s old
  against a 900s ceiling. Until then the full forge lane is correctly blocked.
  818-cgpn should make the smoke lane survive it; that is unverified.
  **801-x1nx** still needs your call. **814-iyu7** (two implementations of
  798-tk7b) needs a surface-ownership decision.

- **NOT done**: §2/§3 of the e2e (unreachable by the runbook's own rule);
  406's runtime half; 802-2536; 767-qrbv. `--install` bumped VERSION three
  times this cycle (702-eusw) and was reverted each time.
