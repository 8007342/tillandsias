# Litmus checkers vs their own war stories, and toolbox env gates — 2026-08-07

- **Host:** linux_immutable (tlatoani), agent linux-tlatoani-claude-20260807t013000z
- **Cycle:** 606-h9vy drain (meta-orchestration full mode)
- **Class:** optimization (checker robustness + immutable-host litmus friction)

## Finding 1 — FIXED THIS CYCLE: substring checkers fire on corpus prose that quotes them

`litmus:expert-capability-skew-honesty` step 5 matched `*'error: unknown
subcommand'*` anywhere in a subcommand's combined output. `tillandsias-plan
loop-status` folds `plan/loop_status.md`, whose prose LITERALLY quotes that
string — in a note describing an earlier fix to this same step. The checker
went red on its own war story, for the second time in its history.

**Fix (landed this cycle):** prefix-anchor the match (`case $out in 'error:
unknown subcommand'*`) — the refusal is always the first line of output, while
corpus content can contain anything. General rule worth keeping: a checker
that greps free prose corpora must anchor on structure (first line, exit code,
stderr channel), never on a bare substring, because this project's corpora
narrate their own defect history and will eventually quote every error string
the tooling emits.

## Finding 2 — FIXED THIS CYCLE: hardcoded count pin went stale on an honest capability addition

`litmus:capability-manifest-guard` step 2 pinned the drifted artifact's token
count as a literal `= 24`. Order 606-e2hg (2026-08-06) legitimately grew the
capability set to 26, so the guard went red on an honest addition — the exact
inversion of what a drift guard is for. Fixed by computing the expectation
from the checkout manifest (`tokens_in_capabilities.txt - 1`).

## Finding 3 — OPEN: the litmus runner env-fails podman-free litmuses when podman is unresponsive

Inside the `tillandsias-builder` toolbox on this immutable host, `podman` is
not usable (nested-container namespace), and the runner's environment gate
reported `[ENV-FAIL] podman unresponsive (>5s)` for
`litmus:expert-groundtruth-harness` — a litmus whose steps never touch podman
(cargo + jq + sed only). The suite then reads as FAIL on a host where the
graded behavior is perfectly checkable. Smallest next action: scope the
podman responsiveness gate to litmuses that declare a podman/container
precondition, so cargo-only litmuses run on toolbox/immutable hosts.
Workaround this cycle: ran the suite on the host directly (host podman is
responsive; host cargo + jq suffice).

Related friction, container-local not repo state: the `tillandsias-builder`
toolbox lacked `jq` (litmus steps need it beside cargo); installed via
`dnf install jq` into the toolbox this cycle.
