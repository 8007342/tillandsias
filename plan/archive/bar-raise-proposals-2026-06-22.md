# Bar-Raise Proposals — 2026-06-22

- branch: linux-next
- status: proposal (Tlatoāni-gated, not self-escalated)
- filed: 2026-06-22T06:46Z
- host: linux_mutable
- agent: big-pickle
- principle: methodology/convergence.yaml → bar_raise_governance

## Context

All plan/index.yaml nodes are completed. Zero residual findings at the current
bar (110/110 litmus instant PASS, build.sh --check pass, credential channel OK,
all sibling branches merged). Per the Reduction Engine's bar-raise governance,
the loop proposes deeper-scan candidates but must not self-escalate — enabling
any of these is an explicit Tlatoāni decision.

## Candidate A: clippy items-after-test-module lint (treat as finding)

**Observation**: `cargo clippy --all-targets -- -D warnings` fails on
`crates/tillandsias-policy/src/main.rs:4629`:
```
error: items after a test module
  --> crates/tillandsias-policy/src/main.rs:4629:1
```
The function `run_in_pty_cmd` at line 4820 is defined after `mod tests` at line
4629. Currently this is not a build-blocker because `build.sh --check` only runs
`cargo check` (not clippy), so the lint silently lives in the codebase.

**Bar-raise**: Add `cargo clippy --all-targets -- -D warnings` to
`build.sh --check` (or `build.sh --ci-full`) so that all existing and future
clippy violations are treated as build failures. This would require fixing the
`items_after_test_module` issue in `main.rs` first.

**Cost**: Small — reorder the test module or allow the lint locally.
**Value**: Prevents clippy drift; makes `--check` stricter.

## Candidate B: dev proxy container warning (treat as non-fatal finding)

**Observation**: `build.sh --check` emits:
```
[build] Failed to start dev proxy container
```
This is accepted as non-fatal (the build continues and passes), but the warning
appears every cycle. A failed proxy means the dev caching proxy (Squid) is not
running, so container builds inside the forge may be slower.

**Bar-raise**: Treat the failed proxy as a finding — either fix the
startup condition (diagnose why squid fails to start on this host) or suppress
it with a clean non-error message (e.g. "dev proxy skipped, container builds
will be uncached").

**Cost**: Low-medium (diagnose squid startup, test fix).
**Value**: Eliminates recurring noise in every build.sh output.

## Candidate C: stale CI/forge cache signals (treat as optimization finding)

**Observation**: Prior cycles (e.g. purge-stale-caches at
2026-06-21T03:30Z) found the GHA nix cache was 11.1 GB over the 10 GB LRU
limit. The nix-cache-warm.yml purge config was added, but there is no recurring
signal to detect when caches drift over the limit again.

**Bar-raise**: Add a litmus check or CI step that warns when the nix cache
size exceeds 80% of the LRU limit, so purge is proactive rather than reactive
during release cycles.

**Cost**: Low (one additional curl/gh API call in a litmus script or CI step).
**Value**: Prevents silent cache-eviction velocity hits during release builds.

## Decision

**ALL THREE CANDIDATES APPROVED** — Tlatoāni (bulloncito@gmail.com), 2026-06-23.

Scope: All three bar-raises are enabled immediately and promoted to `ready`
plan packets for the current linux_mutable host. The loop now treats:
- A: `cargo clippy --all-targets -- -D warnings` failures as build-blocking findings
- B: `[build] Failed to start dev proxy container` as a finding requiring fix or suppression
- C: nix cache exceeding 80% of 10 GB LRU limit as an actionable finding

See plan/index.yaml packets: bar-raise-clippy-strict, bar-raise-dev-proxy-noise, bar-raise-nix-cache-signal.
