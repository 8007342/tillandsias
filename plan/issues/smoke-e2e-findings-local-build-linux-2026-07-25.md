# Local-build Linux smoke findings - 2026-07-25

- **Verdict**: FAIL at Gate 1 (build + CI); later gates not reached
- **Host**: mutable Linux
- **Branch/commit**: `linux-next` at `7dfc2101a6d711cefb254a2af195cbe468f70a9c`
- **Version under test**: `0.3.260724.1`
- **Discovered by**: `/build-install-and-smoke-test-e2e (linux)`
- **Evidence**: `target/build-install-smoke-e2e/20260725T042200Z/`

## Gate results

| Gate | Result | Evidence |
|---|---|---|
| 0 preflight | PASS | `00-host.txt`, `00-commit.txt`, `00-status.txt`, `00-version.txt` |
| 1 build/install | FAIL during `--ci-full`, before install | `01-build-install.log:1528-1544`, `2969-2970`, `3223-3226`, `3275-3276` |
| 2 destructive reset | NOT RUN | Gate 1 stop contract |
| 3 cold init | NOT RUN | Gate 1 stop contract |
| 4 forge meta-orchestration | NOT RUN | Gate 1 stop contract |

The full pre-build litmus reached 203 PASS / 2 FAIL. Both failures reduce to
the same live-ledger defect:

```text
token-lifecycle-policy: depends_on -> unresolved reference '246a'
git-mirror-forwarding-e2e: depends_on -> unresolved reference '247a'
```

`cargo test -p tillandsias-plan --lib` failed
`live_ledger_reference_integrity_holds` and
`append_event_inserts_and_flush_guard_accepts` on those references. The
pre-build `litmus:plan-engine-invariants-shape` independently rejected the same
two references. This is de-duplicated into
`plan/issues/plan-depends-on-order-number-instead-of-packet-id-2026-07-23.md`,
reopened with the exact recurrence and repair.

The failed CI transiently advanced the local date/build version and regenerated
a one-record failed dashboard. Those out-of-scope generated changes were not
accepted as product state. Accurate trace-index line shifts caused by the
already-committed order 463 source change are retained for checkpointing.

No Podman reset, install, cold init, agent launch, release action, tag, or
workflow dispatch occurred.

## Same-cycle repair

The two dependencies now use stable packet IDs:
`credential-inventory-audit` and `tls-certificate-chain-audit`.
`cargo test -p tillandsias-plan --lib` passes 8/8, and the focused
`spec-traceability` quick run passes 7/7 including all four
`litmus:plan-engine-invariants-shape` steps. A full Gate 1 retry remains the
next action before any destructive reset.

## Gate 1 retries

The first retry passed the repaired plan engine but failed one pre-build check:
the ignored/generated image cheatsheet tree lacked the newly added
`enclave-service-catalog-research.md`. Refreshing that tree made the focused
sync litmus pass 2/2 and the next pre-build run pass 205/205. This recurrence is
recorded on existing order 448.

The final retry completed pre-build, built and installed local version
`0.3.260725.1`, and then failed two post-build litmus tests:

- `litmus:running-image-freshness`: stale canonical tag masked by an inherited
  source-digest label; filed and same-cycle fixed as order 488. The six-case
  fixture and focused four-step post-build litmus now pass.
- `litmus:opencode-prompt-e2e-shape`: full meta-orchestration correctly refused
  the build-generated dirty checkout, so HEAD did not advance; filed as order
  489.

The checkout's transient version/dashboard generation was not accepted as
source state. The dedicated Gate 2 Podman reset, cold init, and final forge leg
were not run. No release action occurred.

## Order 489 checkpoint retry

At `linux-next` checkpoint `02503422`, order 489's focused fixtures, 8/8
meta-orchestration instant litmus, 2/2 clickable-trace-index quick litmus, and
`./build.sh --check` pass. The checkpoint is pushed and the worktree is clean.

Before retrying the forced full install chain, the required structured probe
returned:

```text
$ scripts/e2e-preflight.sh eligibility
skip:live-runtime-present
```

The live containers are `tillandsias-vault` and `tillandsias-router`; they
predate this retry. Per completed order 442, the cycle did not bypass the guard
or destroy that operator/shared runtime. Consequently
`TILLANDSIAS_E2E_FORCE=1 ./build.sh --ci-full --install --strict --filter
meta-orchestration` was not started, and reset/init/forge gates remain not run.
The smallest next action is to rerun after the live stack exits, or for the
operator to explicitly authorize this invocation to destroy it.
