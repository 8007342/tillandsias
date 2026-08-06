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
generated-evidence paths. The generated version/trace outputs are checkpointed
with their source changes before the retry so the next clean-tree gate can
distinguish a real nondeterministic mutation from expected source evolution.

## Retry contract

Before retrying, focused compaction tests, the real-ledger compaction test,
image-squashing unit tests, the init incremental-build litmus, and
`./build.sh --check` must be green. The full build/install is then rerun from a
clean pushed checkpoint. Podman reset remains forbidden unless that gate and
installation succeed.
