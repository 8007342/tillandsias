# Linux Local-Build E2E Smoke Findings 2026-08-05

- **Host**: `linux_mutable` (`macuahuitl`)
- **Branch**: `linux-next`
- **Commit tested**: `b49a2c6c654e369f2eb1e22332dc8e55f2ff9849`
- **Run ID**: `20260806T005149Z`
- **Discovered by**: `/build-install-and-smoke-test-e2e` (Linux)
- **Evidence**: `target/build-install-smoke-e2e/20260806T005149Z/`
- **Verdict**: FAIL at gate 1; install, destructive reset, cold init, and forge
  launch were not reached.

## Gate results

- Build and install: **FAIL** (`build_install_exit=141`).
- Installed binary remained the prior `Tillandsias v0.4.260804.1`.
- Destructive Podman reset: **NOT REACHED**, as required after a failed build.
- Cold `tillandsias --debug --init`: **NOT REACHED**.
- In-forge meta-orchestration: **NOT REACHED**.

## Finding 606-h9vy: real-ledger text compaction rejected non-scalar LWW values

`fragments::compaction_text_tests::compaction_on_the_real_ledger_preserves_every_comment_and_item`
failed because the text-preserving compactor only knew how to replace scalar
values. The first trigger was an audit fragment that used whole-field LWW to
overwrite order 451's sequence-valued `depends_on` and folded-string
`blocked_on` with audit sequencing that should instead have remained additive
packet/event facts. Restoring those semantic values append-only then exposed
the general compactor defect for legitimate pre-existing whole-field updates
and for fragment-born packets whose folded winner was already rendered.

The checkpoint repair replaces only the exact field span for scalar,
flow/block sequence, mapping, and block-string YAML values without a YAML
round-trip, avoids reapplying the LWW winner to fragment-born packets, and adds
focused and live-ledger compaction regressions. The audit's semantically
incorrect overwrites are superseded by
`plan/index.d/20260806t010300z-606-lww-correction-linux-mutable.yaml`; no
immutable fragment was edited.

This is partial progress on order 606-h9vy. The packet's citation provenance,
authority verification, and folded-corpus freshness criteria remain open.

## Finding: generated trace evidence made the local CI self-clean check red

The checkout entered the smoke with newly added traces whose generated
`TRACES.md` indexes were not yet committed. The build correctly regenerated
them, then `litmus:local-ci-self-clean-evidence` rejected the resulting dirty
generated-evidence paths. The generated trace outputs are checkpointed with
their source changes before retry. Local build-version bumps are deliberately
restored instead of entering `linux-next`; the pre-push version guard reserves
those commits for the release flow on `main`.

## Retry 2 — stale trace indexes passed the advertised pre-push gate

- **Commit tested**: `1bf1047b11eac5ac0cd98ab3680a97af84bc422f`
- **Run ID**: `20260806T014047Z`
- **Evidence**: `target/build-install-smoke-e2e/20260806T014047Z/`
- **Verdict**: FAIL at gate 1 (`build_install_exit=141`); the run was
  interrupted immediately after the first aggregate RED was captured.
- **Installed binary**: unchanged at `Tillandsias v0.4.260804.1`.
- **Reset/init/forge**: **NOT REACHED**.

The required `./build.sh --check` passed and the pre-push hook accepted the
exact checkpoint, but neither ran `scripts/generate-traces.sh --check`. The
subsequent full build regenerated 61 stale trace indexes whose line numbers
had moved during the final reviewed fixes, then
`litmus:local-ci-self-clean-evidence` failed at step 4 with
`fail:generated-evidence-dirt` (`01-build-install.log:1948-2018`). The existing
order 490 intentionally proves that check-only mode does not *generate*
indexes; it does not prove that the advertised pre-push gate *rejects* stale
ones. The regenerated indexes are deterministic and are checkpointed before
retry 3. The residual is recorded on existing order 584-2qq2; the related
post-commit dashboard side effect is recorded on existing order 489, avoiding
duplicate packets.

## Retry 3 — recurring launch-marker suite race

- **Commit tested**: `a10a23364762ab44026172ae9c706bf290f91257`
- **Run ID**: `20260806T015251Z`
- **Evidence**: `target/build-install-smoke-e2e/20260806T015251Z/`
- **Verdict**: FAIL at gate 1 (`build_install_exit=141`); the run was
  interrupted immediately after the aggregate test gate turned red.
- **Installed binary**: unchanged at `Tillandsias v0.4.260804.1`.
- **Reset/init/forge**: **NOT REACHED**.

Trace freshness was clean, but the 390-test tray-feature run reproduced the
existing order 584-e8pe race at
`tests::shared_stack_launch_marker_lifecycle_and_own_exclusion`: 387 passed,
one failed, and two were ignored in 19.15 seconds. The dropped guard's lock
was still visible at the assertion. The exact test passed immediately alone,
and an unchanged full-suite retry passed all 388 runnable tests in 20.04
seconds. This matches the 2026-08-01 residual rather than opening a duplicate.

The failure is consistent with the fork-to-exec inherited-fd window already
documented by the resource-lock unit test: another suite test can fork while
the guard fd is open, and `O_CLOEXEC` takes effect only at exec. The failure
log does not identify the holder, so that remains an evidence-backed inference
rather than a proven per-process fd trace.

Order 584-e8pe was repaired without weakening the immediate-release contract.
The test re-execs exactly itself in an isolated child with a private temporary
`XDG_RUNTIME_DIR`, asserts that the child executed one test (preventing a
vacuous `--exact` pass), keeps the immediate post-drop assertion, and explicitly
removes the fixture. The focused test passed, followed by five internally
concurrent full tray-feature suites; every run reported 388 passed, zero
failed, and two ignored in 18.90–19.19 seconds.

## Retry contract

Before retrying, focused compaction tests, the real-ledger compaction test,
image-squashing unit tests, the init incremental-build litmus,
`scripts/generate-traces.sh --check`, and `./build.sh --check` must be green.
Order 584-e8pe must additionally pass focused, repeated full-suite, and
concurrent verification. The full build/install is then rerun from a clean
pushed checkpoint. Podman reset remains forbidden unless that gate and
installation succeed.
