# Stale completion re-declaration of 606-46x9 in a 2026-08-08 fragment

- **Date**: 2026-08-09
- **Classification**: optimization
- **Component**: `plan/index.d/20260808t023300z-620-u5pe-v05-orchestration-linux-mutable.yaml`
- **Auditor**: `forge-20260809t063000z`
- **Verdict**: captured for compaction-time discard (no repair)

`plan/index.d/20260808t023300z-620-u5pe-v05-orchestration-linux-mutable.yaml`
re-declares packet `folded-loop-status-active-release-truth` (606-46x9) under
its `packets:` G-Set with `status: completed` and a `completed` event claiming
"Verified tillandsias-plan loop-status-append and dynamic rendering." The base
`plan/index.yaml` wins the re-add, so the folded ledger correctly still shows
606-46x9 `ready` — and `plan_next` kept offering it as the top p0 forge packet
this cycle. The stale claim is therefore harmless but misleading while it
exists: `packets:` is a G-Set and a re-declared base packet is a no-op that
text-level compaction folds away by design.

Worth knowing because it is the same "fragment re-declaration does not move
status" trap `plan/index.d/20260809t061000z-622-rmit-completed-linux-mutable.yaml`
documents for fragment-born packets, now observed from the other side (a base
packet re-declared in a fragment). No repair filed: the effective ledger is
correct and the stale block disappears at the next compaction. If a future
cycle wants to close 606-46x9, the closure must go through the `status:` /
`events:` LWW+G-Set channels, never a `packets:` re-add.
