# CCR sandbox sessions cannot publish ledger claims to linux-next — leases invisible to siblings

- **Date**: 2026-07-06
- **Host**: linux_mutable (Claude Code remote sandbox)
- **Classification**: optimization (coordination-velocity drag)
- **Status**: open — intake
- **Filed by**: linux-ccr-fable5-20260706T1734Z (meta-orchestration cycle 2026-07-06T17:34Z)

## Observation ("this isn't great")

Claude Code remote (CCR / claude.ai/code) sessions are pinned to a
session-specific branch (`claude/<slug>`) and are forbidden from pushing to any
other branch. The worker protocol (`advance-work-from-plan` §3) requires a
claim event to be pushed to `origin/linux-next` **before** implementation so
concurrent agents see the lease. From a CCR session that push is impossible:
the claim lands on the session branch and only reaches `linux-next` when the PR
merges — i.e. **after** the work is done. During the whole cycle the lease is
invisible to every sibling agent reading `origin/linux-next`.

`scripts/claim-ledger-node.sh` does not close the gap either: its lease root is
host-local (`$XDG_RUNTIME_DIR|/tmp`), and CCR containers are ephemeral and
never shared with sibling hosts.

Consequence: the exact idempotent-but-wasteful collision documented in
`plan/issues/agent-concurrency-collisions-2026-06-20.md` becomes *likely*
rather than rare whenever a CCR session drains a ready packet concurrently
with scheduled linux/macos/windows loops — two agents can complete the same
packet in parallel with no way to see each other.

## This cycle's exposure (concrete instance)

Cycle 2026-07-06T17:34Z claimed and completed `race-safeguards-research`
(order 160) entirely on `claude/meta-orchestration-skill-uhitvv`. If any
scheduled host loop picked the same packet before the PR merges, both cycles'
effort is duplicated (converging edits are safe per the CRDT merge rules, but
one full cycle of effort is wasted).

## Smallest next actions (candidate reductions)

1. **Cheapest**: teach packet selection to deprioritize `pickup_role: any`
   research packets on CCR hosts when an equally eligible host-exclusive packet
   exists (fewer collision surfaces; CCR picks work siblings cannot do).
2. **Remote-visible advisory lease without branch writes**: publish the lease
   as a git ref outside branch namespaces (e.g. push a tag-like ref
   `refs/tillandsias/leases/<node-id>` — needs confirmation that the CCR proxy
   allows non-branch ref pushes) or via a GitHub issue label/comment through
   the API. Either makes the lease visible in seconds without touching
   `linux-next`.
3. **Merge-fast policy**: CCR-authored ledger PRs that only touch `plan/` could
   be auto-merged by the coordinator loop on its next cycle, shrinking the
   invisibility window from "until a human merges" to ≤1 coordinator period.

## Verifiable-constraint sketch (for promotion to a ready packet)

A litmus that runs `scripts/claim-ledger-node.sh claim <id>` on two simulated
hosts with distinct lease roots and asserts the second caller observes
`in-flight:<id>` — currently impossible cross-host, which is precisely the gap;
the check should pass once option 2 (remote-visible lease) is implemented.
