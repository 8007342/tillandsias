# Multi-Agent Work Shaping + Status Packets - 2026-05-25

trace: methodology/distributed-work.yaml, methodology/multi-host-development.yaml, .codex/skills/coordinate-multihost-work/SKILL.md

Status: **ACTIVE CANON** as of 2026-05-25T19:30Z. This issue is the durable
coordination note for making recurrent Linux, Windows, and macOS agents work in
larger, evidence-producing packets instead of tiny sequential chores.

## Work Packet Rule

A claimable packet should normally occupy one or two recurrent prompt iterations
and end with evidence another host can consume. Fold tiny cleanup, one-file
wiring, and obvious follow-on edits into the nearest feature, verification,
packaging, or CI packet unless that tiny item directly unblocks another host.

Split work only at one of these boundaries:

- Different `owner_host`.
- Different dependency gate or upstream artifact.
- Different acceptance evidence.
- File scopes that would create avoidable lease collisions.

Each ready packet should name:

- `next_action`: the first concrete edit or command.
- `acceptance_evidence`: tests, smoke output, commit refs, or logs.
- `dependency_contract`: exact artifact/API/commit expected from upstream work.
- `fallback_when_blocked`: useful work the same host can claim if blocked.

## Eager Assignment Rule

Each active platform queue should always expose at least one unblocked ready
packet. If the main path is gated, publish a fallback packet for verification,
packaging, CI, diagnostics, or docs distillation. The coordinator should not let
Windows or macOS sit idle merely because a Linux dependency is still in flight.

Current fallback intent:

- Windows: if w4 ConPTY stalls or w5 remains gated, claim w6 verification or
  cache/diagnostics work that does not depend on the rootfs artifact.
- macOS: m4 and m6 are both ready while m5 waits for the materializer/rootfs
  chain; m4 host-side wiring can proceed before the full Hello/HelloAck smoke.
- Linux: l7 materializer remains the highest-impact dependency tail; if it
  stalls, publish its narrowest failed diagnostic chain and split only by
  materializer API, cache/export, and CI evidence boundaries.

## Remote Progress Health

Recurrent agents should normally find `origin/linux-next` ahead of their local
checkout. That is expected and healthy: it means another agent, the integration
loop, or a sibling branch merge made progress while this agent was asleep.

Do not report "remote is ahead" as a blocker by itself. The actionable cases are:

- Remote advanced and local dirty state/conflicts/sandbox limits prevent a
  fresh fetch, rebase, or ledger update.
- Remote heads do not advance for multiple expected cycles even though active
  agents should be producing commits or status packets.
- A branch advances but the corresponding queue headers/events are stale and
  need reconciliation.

When remote advanced, record the observed heads, fresh-read the changed ledgers,
and continue with reconciliation. When remote does not advance, document the
no-progress streak and the host/job that should be checked.

## Agent Status Packet

Append this shape under the owning item's Events section whenever claiming,
ending an iteration, blocking, failing, releasing, or completing work:

```yaml
status_packet:
  item: "<stable-id>"
  ts: "<UTC ISO-8601>"
  agent_id: "<host-workstation-harness>"
  lease_id: "<lease>"
  state: "claim|plan|progress|blocked|failed|released|completed"
  current_plan:
    - "<implementation step>"
  dependencies:
    - "<upstream item/artifact/API/decision>"
  blockers:
    - "<blocker, owner_host if known, next ping/check time>"
  errors:
    - "<command/error summary plus smallest diagnostic chain>"
  files_touched:
    - "<path or glob>"
  evidence:
    - "<commit/test/log/smoke result>"
  next_checkpoint: "<next action and ETA/trigger>"
  lease_intent: "continue|release|reclaimable_after:<UTC>|done"
```

Keep packets concise. If details become long, move them to the owning issue or a
focused log artifact and leave a pointer here.

## Coordinator Duties

- Reconcile item headers from terminal status packets before assigning work.
- Keep dependency mirror tables current when gates clear.
- Prefer larger coherent packets over micro-tasks.
- Ensure every active host has ready work plus a fallback.
- Ping stale leases before reclaiming; reclaim only after TTL expiry or an
  explicit `released`/`failed` event.
- Move durable guidance into methodology; keep `plan/loop_status.md` as the
  short quick-start cache.
