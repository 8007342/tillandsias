# meta-orchestration Specification

@trace spec:meta-orchestration

## Status

active

## Purpose

The unattended top-level loop: how a host runs one work cycle — heartbeat,
drain, verify, attest — without a human watching. The runbook lives in
`skills/meta-orchestration/SKILL.md`; THIS document pins the invariants that
runbook may never lose, each falsifiable by the litmus tests bound in
`openspec/litmus-bindings.yaml` (spec_id `meta-orchestration`). This spec was
registry-asserted (40+ `@trace` sites, 19 litmus bindings, 100% coverage
ratio) for months before the file existed — order 877 closed that ghost.

## Requirements

### Requirement: A full cycle proves its own exit

A full-mode cycle MUST NOT report success by exit code alone. It ends with a
`MO-FULL: <DISPOSITION> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>` marker that is
DERIVED from live git state (`scripts/mo-full-attest.sh self`), recorded
durably (`record` → `plan/mo-full-attestations.d/<host>.md`), and only after
the local head is verifiably the converged remote head.

#### Scenario: Unpushed work cannot attest

- **WHEN** a cycle's local HEAD is not on the remote (push failed, forgotten,
  or the SHA was fabricated)
- **THEN** `mo-full-attest.sh` MUST refuse to emit or record the marker
- **AND** the missing marker is itself the loud failure
  (litmus:mo-full-attestation-ledger-shape, order 614-2gqx / 651-2x5s)

### Requirement: The startup boundary is inviolable

A cycle snapshots the worktree at start (`meta-orchestration-worktree-guard.sh
snapshot`) and MUST leave every pre-existing dirty path byte-identical on
every exit, verifying the boundary at the HEAD being attested. Dirty-start
trees are refused, and refusal MUST be preceded by a salvage push
(`salvage-dirty-worktree.sh`) so the refusal can never orphan the work it
protects.

#### Scenario: Dirty tree preserved, not consumed

- **WHEN** a cycle starts over uncommitted sibling or operator work
- **THEN** the cycle refuses committable work, salvages the tree to
  `refs/heads/salvage/*`, and exits without mutating the recorded paths
  (litmus:meta-orchestration-dirty-tree-safety, litmus:salvage-net-roundtrip;
  orders 872-c9nd, 874-s8vf, 874-w2gc)

### Requirement: One checkout, one cycle

Every lane that can start a cycle — driver timer, operator prompt, /loop
cron — MUST acquire the checkout lock (`cycle-checkout-lock.sh`, mkdir arm;
driver flock arm; cross-arm visibility both directions) before committable
work, and release it as the cycle's last mutation. A second agent NEVER works
in a locked checkout; separate worktrees or clones are the sanctioned path.

#### Scenario: Overlapping lanes arbitrate instead of stacking

- **WHEN** a prompt-lane cycle fires while a driver cycle holds the checkout
  (or vice versa)
- **THEN** the newcomer yields with `skip:overlap-lock-held`, recording the
  refusal durably outside the contended checkout (order 873-zcim)

### Requirement: Guards run before work, and fail loud

Before worker drain a cycle MUST verify its instrument
(`cycle-preflight.sh` — rebuild `tillandsias-plan`, re-verify after every
mid-cycle pull), its credential channel (`check-credential-channel.sh` — a
PUSH-verified probe, never configuration inspection), and its committable
branch. Verdicts are single-line, machine-parseable, and each guard has been
seen RED before being trusted.

#### Scenario: A guard that cannot fail is not a gate

- **WHEN** a guard's failing branch is unreachable in its fixture
  (e.g. `gh auth status` green while `git push` hangs interactive)
- **THEN** the guard is defective by definition and must be repaired with a
  mutation control demonstrating the red path
  (litmus:credential-channel-check-shape, orders 860-g798, 851-cduu)

### Requirement: Every mode names its verdict

The skill's invocation modes (full, smoke, targeted verify) are decided from
the invoking prompt BEFORE any work, and each ends in its pinned grammar —
`MO-FULL:` for full, `MO-SMOKE: PASS|FAIL <reason>` for smoke. A smoke run
leaves the repository untouched.

#### Scenario: Smoke never spends the full-cycle budget

- **WHEN** the invoking prompt contains `smoke`
- **THEN** the run performs verify-only checks inside ~5 minutes, emits
  `MO-SMOKE:` as its final line, and neither claims, commits, nor pushes
  (litmus:opencode-prompt-e2e-shape, litmus:forge-e2e-rate-limit-shape)

## Sources of Truth

- `skills/meta-orchestration/SKILL.md` — the operational runbook
- `scripts/mo-full-attest.sh`, `methodology/mo-full-attestation.yaml`
- `scripts/cycle-checkout-lock.sh`, `scripts/meta-orchestration-worktree-guard.sh`
- `scripts/check-credential-channel.sh`, `scripts/cycle-preflight.sh`
- `openspec/litmus-bindings.yaml` (spec_id `meta-orchestration`)
