# The pre-build litmus corpus is not host-aware: bare on Windows it fails 55/236 for environmental reasons

- Date: 2026-08-03
- Class: enhancement (host-aware litmus routing / eligibility gating)
- Filed by: windows-claude-fable-metaorch-20260803 (order 598-yhu5 W6, windows-next e81819f0)
- Related: 598-c4ug (instruction files not host-aware — same class, test corpus
  edition), plan/issues/cfg-gated-tray-code-never-typechecked-2026-07-21.md

## Measured (W6, 2026-08-03)

`scripts/run-litmus-test.sh --phase pre-build --size quick --compact` run BARE
on the Windows host, exactly as 598-yhu5 W6 prescribed:

```
PASS: 181   FAIL: 55   SKIP: 114   (executed: 236)
Coverage: 100% [96/96 specs]   Pass Rate: 76%   Status: FAIL
```

Host tool resolution (checked first, per the packet): `timeout` and `md5sum`
resolve natively (GNU coreutils via Git Bash — the run-litmus-test.sh:825
`timeout --kill-after` wrapper works); `jq`, `yq`, `ruby`,
`tillandsias-policy` do NOT resolve natively.

30 of the 55 failing tests were captured with step context before a re-run hit
its wall-clock cap; every captured failure is environmental, not a Windows
regression:

- **Native-compile class** (15 E0381 occurrences): steps that `cargo
  test`/`cargo run` tillandsias-headless or its dependents natively —
  accel_probe.rs declares physical_cores/logical_cores only under
  cfg(linux)/cfg(macos) and reads both unconditionally. Documented
  non-regression (598-yhu5 W1 note); it means every headless-touching litmus
  step is unrunnable bare on Windows. Hits litmus:opencode-vault-auth-content,
  litmus:vsock-exec-heartbeat, litmus:headless-init-status-check-source-built,
  and others.
- **Linux-substrate class**: forge/expert MCP fixtures, git-mirror-service
  offline fixtures (9 tests), image-build-convergence, forge-validation-profile
  — need podman, a built guest, or forge lanes that exist only in the Linux/WSL
  substrate.
- **Suspected genuinely stale, VERIFY ON LINUX**: litmus:ci-release-toolchain-shape
  step 3 asserts "ci.yml is check-only", and litmus:local-ci-self-clean-evidence
  also fails — ci.yml was removed from every branch by the 2026-08-03 Actions
  purge (PR #86). If these fail on Linux too, they are purge residue of the
  exact class 598-u97y named (the litmus verified where it was written): the
  corpus still pins a workflow file the project deleted. One command to check.

## Why it matters

598-yhu5 W2's note predicted this ("run-litmus-test.sh has no WSL wrapper, so
it runs BARE on Windows"); it is now measured. A 76% pass rate that means
"wrong host" rather than "broken code" trains agents to ignore litmus FAILs —
the same false-signal failure the project keeps naming. Windows cycles need
either a documented spec-filtered subset, host-eligibility `skip:` verdicts per
test (the e2e-preflight pattern), or WSL routing for the substrate-dependent
corpus.

## Smallest next step

Per-test host-eligibility metadata (e.g. `requires: [podman, linux-compile]`)
consumed by run-litmus-test.sh as structured `skip:<reason>` — turning the 55
environmental FAILs into SKIPs so a Windows FAIL means something again. And on
Linux: confirm or refute the two ci-release shape tests against the post-purge
tree.

## Addendum, same cycle: hard-killed litmus runs corrupt the checkout

The second W6 run was hard-killed at a 600s harness cap mid-corpus, and the
worktree was left with `VERSION` containing `0.0.0-test-retag` —
scripts/test-image-build-convergence.sh rewrites the REAL tracked VERSION
(line 69), and its `trap cleanup EXIT` (line 31) plus `$tmp` backup cannot run
on a hard kill (SIGKILL/taskkill /F never executes traps; the mktemp backup
dies with the process). Restored via `git restore VERSION` against the
committed state; the orphaned runner process tree (still executing inside a
300s step after its parent died) was terminated before finalization.

Durable fix direction: fixtures that mutate tracked workspace files should run
against a copy (or restore from git, not from a process-lifetime tmp path).
Any litmus step that edits a tracked file in place has this kill-window, and a
runner killed by budget caps is a NORMAL event on constrained hosts, not an
anomaly.
