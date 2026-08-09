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

## Retry 4 — automated smoke invoked the operator-only host supervisor

- **Commit tested**: `40a8773bec4c1a3356192c02467e574d1f179991`
- **Run ID**: `20260806T045626Z`
- **Evidence**: `target/build-install-smoke-e2e/20260806T045626Z/`
- **Start boundary**: clean; `00-preflight.txt` records the repository root,
  `host_kind=linux`, `host_branch=linux-next`, and executable `build.sh`.
- **Source version**: `0.4.260804.1`.
- **Installed binary**: `/home/tlatoani/.local/bin/tillandsias`,
  `Tillandsias v0.4.260806.1`, 41 MiB, musl-static.
- **Verdict**: FAIL at gate 1 (`build_install_exit=1`) during the post-build
  status smoke; destructive reset, cold init, and the outer forge launch were
  not reached.

The expensive build portions were green before the first aggregate RED: the
tray-feature suite reported 388 passed, zero failed, and two ignored; pre-build
litmus reported 238/238 executed with 96/96 spec coverage; and the aggregate
build gate reported 17/17. All ten versioned images were constructed and Vault
bootstrapped. The post-build litmus then failed
`litmus:opencode-prompt-e2e-shape` step 3:

```text
repeat: unable to find opencode; set OPENCODE_BIN=/path/to/opencode
repeat: harness 'opencode' binary unavailable; aborting
FORGE_EXIT=2
```

The failure is deterministic contract drift, not an image or provider outage.
`scripts/litmus-opencode-e2e-launch.sh` still invoked `./repeat --agent
opencode`, while completed order 594-rukb and the script's own source/header
declare `./repeat` a human/operator-only host supervisor. This host correctly
has no native `opencode` on `PATH`; the freshly installed binary and forge image
provide the product-owned on-demand harness path. The gate must launch
`TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt ...`, retain its
full/smoke limiter and delta assertions, and carry a negative regression that
the automated path cannot call `./repeat`.

This finding is deduplicated to open v0.5 order 404,
`codex-e2e-smoke-launcher-and-verdict-parity`; completed order 594-rukb is the
operator-only boundary and is not reopened. The bounded OpenCode repair now
uses the direct installed-product path, and the rate-limit shape pins both that
command and absence of an executable `./repeat` call. A live rate-limited smoke
against the just-built `0.4.260806.1` binary then launched the forge, attached
OpenCode, cloned through the mirror, printed `MO-SMOKE: PASS`, and returned
`FORGE_EXIT=0` (`05-launcher-fix-smoke.log`). Order 404 remains open for its
Codex sibling, shared-stamp, skill-documentation, and verdict-parity criteria.

The install-generated VERSION and crate-manifest/lock bumps were restored
byte-for-byte after the failure. No Podman reset was attempted.

## Retry 5 — clean-store image acceptance passed; full-cycle exit attestation failed

- **Commit tested**: `c9ebd3f594da262594ea81ccb29e68fbd72d3d7c`
- **Run ID**: `20260806T085959Z`
- **Evidence**: `target/build-install-smoke-e2e/20260806T085959Z/`
- **Installed binary**: `/home/tlatoani/.local/bin/tillandsias`,
  `Tillandsias v0.4.260806.1`, 41 MiB, musl-static.
- **Overall verdict**: **FAIL at the full meta-orchestration terminal contract**;
  build/install, destructive reset, cold init, image squashing, OpenCode smoke,
  and forge transport all passed.

The mandatory build/install gate returned zero. Rust, clippy, tray (388 passed,
zero failed, two ignored), signal tests, 239 executed pre-build litmus checks,
17 aggregate gates, 11 post-build checks, and five runtime residual checks were
green. The evidence bundle reported 255 litmus passes and zero failures. The
post-build OpenCode path used the installed product (not `./repeat`), emitted
`MO-SMOKE: PASS`, and satisfied all seven launcher/delta checks.

Only after that success did the destructive gate run. `podman system reset
--force` returned zero; the immediate audit found zero containers, images, and
volumes, and the teardown probe found zero zombies/orphans. Cold
`tillandsias --init --debug` then built all ten images and bootstrapped Vault
from the empty store with `init_exit=0`.

### Squash-new clean-store matrix

Each version alias, content-digest alias, image identity label, and inherited
RootFS prefix was checked directly. Every Containerfile contributed exactly one
new RootFS layer; no inherited base was flattened.

| image | base layers | image layers | delta | prefix | labels/canonical alias |
|---|---:|---:|---:|---|---|
| proxy | 1 | 2 | 1 | PASS | PASS |
| git | 1 | 2 | 1 | PASS | PASS |
| vault | 7 | 8 | 1 | PASS | PASS |
| inference | 1 | 2 | 1 | PASS | PASS |
| router | 5 | 6 | 1 | PASS | PASS |
| chromium-core | 1 | 2 | 1 | PASS | PASS |
| chromium-framework | 2 | 3 | 1 | PASS | PASS |
| forge-base | 1 | 2 | 1 | PASS | PASS |
| forge | 2 | 3 | 1 | PASS | PASS |
| web | 1 | 2 | 1 | PASS | PASS |

The audit also found a stale developer-only `nanoclawv2` selector whose
Containerfile no longer exists and corrected the order-607-owned build/hash
surfaces. The active init spec's cold sequence was corrected from eight to the
actual ten images. A focused default-image run passed 9/9 tests, including the
new retired-selector regression.

### Chromium start exposed a pre-existing probe bug

The rebuilt framework image emitted the expected DOM with network disabled,
read-only root, all capabilities dropped, `no-new-privileges`, keep-id, bounded
PIDs, and ephemeral state when Chromium received `--no-sandbox`. Without that
explicit caller argument, its entrypoint's help-text probe omitted the required
switch and Chromium exited 139 in the zygote host. The first harness attempt
also recorded Podman exit 125 because this Podman rejects `uid=` as a tmpfs
option; the corrected `/tmp`-profile command isolates that harness mistake from
the product defect. Order 612-nvf3 owns the real false-negative probe.

### Full forge transport passed, but the skill did not complete

The final installed-product launch cloned through the mirror, attached
OpenCode, passed all startup guards, and actually called the plan expert. It
reproduced order 600-c266: the folded expert can see a fragment-only packet,
while `append-event` still edits only the base and returns “packet_id not
found”. This is useful live expert evidence and not a duplicate packet.

The agent then made local commit `4a1410a2` for its generated OpenSpec sync and
stopped during implementation analysis. It did not emit a full-cycle verdict,
verify its startup boundary, write a cycle result, or push. Teardown discarded
the clone and commit, yet the provider and outer launcher returned
`forge_exit=0`; `origin/linux-next` remained `c9ebd3f5`. Order 614-2gqx now owns
the missing full-mode terminal attestation. Process exit zero is recorded as a
transport result, not a meta-orchestration PASS.

The install-generated VERSION and crate-manifest/lock bumps were again restored
byte-for-byte. No release is warranted from this run.

## Retry contract

Before retrying, focused compaction tests, the real-ledger compaction test,
image-squashing unit tests, the init incremental-build litmus,
`scripts/generate-traces.sh --check`, and `./build.sh --check` must be green.
Order 584-e8pe must additionally pass focused, repeated full-suite, and
concurrent verification. The full build/install is then rerun from a clean
pushed checkpoint. Podman reset remains forbidden unless that gate and
installation succeed.
