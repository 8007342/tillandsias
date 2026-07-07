# build-install-and-smoke-test-e2e (Linux) — findings — 2026-07-06

- discovered_by: /build-install-and-smoke-test-e2e (linux_mutable)
- host: Linux mutable, `linux-next@32da73a1`
- evidence: `target/build-install-smoke-e2e/20260706T201910Z/01-build-install.log`,
  `/tmp/litmus-pre-build.log`, `/tmp/tray-check.log`

## Result: STOPPED at gate 1 (build + CI + install)

`./build.sh --ci-full --install` exited non-zero via `scripts/local-ci.sh`
before the `--install` step ever ran. Per the skill's guardrail ("If the
build, CI, install, path lookup, or version probe fails, stop. Do not destroy
the runtime substrate."), the destructive Podman reset (gate 2) was correctly
**not** run this cycle. Two independent, pre-existing (not caused by this
cycle's changes — see verification below) issues caused the `local-ci.sh`
gate to fail:

## Finding 1 (research/environment) — `litmus:guest-binary-embed-integrity` blocks `--ci-full` on any checkout without a cross-compiled guest binary

`scripts/local-ci.sh`'s `litmus-pre-build` check runs the full litmus suite
(not just `--size instant`) and treats ANY failure as a hard CI blocker. On
this dev checkout, `target-guest/tillandsias-headless-x86_64-unknown-linux-musl`
does not exist (nobody has run `scripts/build-guest-binaries.sh` here), so
`litmus:guest-binary-embed-integrity` fails with:

```
[build-guest-binaries] ERROR: Missing x86_64 binary at
  /home/tlatoani/2src/tillandsias/target-guest/tillandsias-headless-x86_64-unknown-linux-musl
```

This is the same "local-build-state gap, not drift" already documented in
`plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md` (macOS
found the identical gap). What's new here: on Linux this single litmus
failure is enough to fail `./build.sh --ci-full --install` outright and abort
before `--install` runs, which means **the smoke skill cannot reach its own
destructive-reset/re-provision gates on a fresh Linux dev checkout that
hasn't separately run `scripts/build-guest-binaries.sh` first** — a real
operational gap for exactly the "first-run smoke test" scenario the skill is
supposed to validate.

Candidate reduction (not done this cycle): either (a) have
`scripts/build-guest-binaries.sh` (cross-compile) run automatically as a
`--ci-full`/smoke prerequisite so a fresh checkout self-heals, or (b) have the
litmus runner distinguish "local build-state gap" from "product drift" (ties
into the existing "litmus runner gives no signal for missing tools" finding
in the macOS deliverable above) so `local-ci.sh` can choose to warn instead
of hard-fail on this specific, known-benign case.

## Finding 2 (research/exploration) — `remote_projects.rs` clone tests are flaky under both parallel AND single-threaded execution (shared-state test isolation bug)

`cargo test -p tillandsias-headless --bin tillandsias --features tray` (the
exact command `local-ci.sh`'s `tray-contract` check runs) fails
non-deterministically — a different subset of `remote_projects::tests::*`
fails each run:

```
run 1: clone_uses_host_parent_bindmount, clone_project_uses_containerized_gh,
       git_image_tag_defaults_to_fully_qualified_versioned_tag,
       discover_projects_uses_containerized_gh, test_cache_invalidation (5 failed)
run 2: clone_uses_host_parent_bindmount,
       git_image_tag_defaults_to_fully_qualified_versioned_tag,
       test_cache_invalidation (4 failed)
run 3 (--test-threads=1): clone_uses_host_parent_bindmount,
       discover_projects_uses_containerized_gh,
       git_image_tag_defaults_to_fully_qualified_versioned_tag,
       test_cache_invalidation (4 failed)
```

**Verified this is pre-existing and unrelated to this cycle's changes**:
`remote_projects.rs` was not touched by this session (`git log -3 --
crates/tillandsias-headless/src/remote_projects.rs` shows the most recent
touch is `d98e8eff feat: atomic clone (order 163) + push protocol variants
(order 152)`, well before this session). Reproduces even with
`--test-threads=1` (single-threaded), so it's not pure parallel-scheduling
noise — some cross-test shared state (a `test lock: PoisonError` appears in 3
of the 4 failures, meaning an earlier test's real panic poisoned a shared
`Mutex` used by later tests in the same process; the 4th,
`clone_uses_host_parent_bindmount`, has a real assertion mismatch —
`"/tmp/.tmpXXXX/lakanoa.tmp.<hash>"` vs the expected `"/tmp/.tmpXXXX/lakanoa"`
— that looks like the actual root panic, likely order-163's atomic-clone
staging-then-rename path leaking its `.tmp.<hash>` intermediate name into an
assertion that expects the final post-rename name).

This is a real, actionable test-isolation bug (root-caused to
`clone_uses_host_parent_bindmount`'s stale expectation about the atomic-clone
staging path, poisoning a shared mutex for the rest of the suite) blocking
`local-ci.sh`'s `tray-contract` gate non-deterministically. Filed here rather
than fixed in this smoke-skill session (out of scope: the skill files
findings, it doesn't implement product fixes — per its own contract, "Do not
implement product fixes during this skill").

## Work (next reduction step)

1. Whoever owns `crates/tillandsias-headless/src/remote_projects.rs` (order
   163's atomic-clone area) should: (a) fix
   `clone_uses_host_parent_bindmount`'s assertion to account for the
   staging-then-atomic-rename path (or fix the implementation if the
   intermediate name is genuinely leaking), and (b) make the shared test
   `Mutex` poison-recoverable (e.g. `.unwrap_or_else(PoisonError::into_inner)`)
   so one test's panic doesn't cascade-fail unrelated tests in the same
   binary.
2. Consider whether `build-guest-binaries.sh` should run automatically ahead
   of `--ci-full` (Finding 1) so a fresh checkout doesn't need a manual
   cross-compile step before the smoke skill can proceed past gate 1.
3. Re-run `/build-install-and-smoke-test-e2e` once both are fixed to actually
   exercise gates 2-4 (destructive reset, re-provision, forge lane) against
   this cycle's integrated litmus/order-124/order-153/macOS/Windows work.
