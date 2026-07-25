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
