# Optimization: ledger node-claim lease is same-host-only

- branch: linux-next
- status: open
- kind: optimization
- owner_host: any
- source: meta-orchestration cycle 2026-06-21T01:04Z (order 62 implementation)
- relates_to: plan/index.yaml order 62 (ledger-edit-claim-lease), order 66
  (forge-push-credential-channel)

## Finding

`scripts/claim-ledger-node.sh` (order 62) reserves a `plan/index.yaml` node
closure via an `mkdir(2)` lease under
`${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks/ledger-nodes`. That root is **local
to a single host**, so the single-winner guarantee only holds for concurrent
cycles on the *same* machine (the common case today: multiple agents —
opencode/codex/claude/gemini — sharing one Linux host, which is exactly the
collision recorded in `agent-concurrency-collisions-2026-06-20.md`).

It does **not** prevent the cross-host case: two different hosts (e.g. a Cowork
sandbox and big-pickle) can still independently claim and re-derive the same
node closure, because neither sees the other's local lease. This is acceptable
and by design for now — the merge remains idempotent and CRDT-friendly, so a
cross-host collision is wasteful but never corrupting — but it is a known
ceiling on the optimization, not a complete fix.

## Why it's deferred, not closed

A cross-host claim would need a *shared* lease channel. The natural substrate is
the git ledger itself: a short-lived `type: claim` event with `lease_id` +
`expires_at` written to the node and pushed before re-derivation (the pattern
already used informally in `agent-concurrency-collisions-2026-06-20.md`'s
codex events). That couples claiming to a push round-trip and needs the
forge-push credential channel (order 66) to be reliable from every host first,
and it reintroduces a claim/merge race at the git layer. Low ROI until (a)
cross-host concurrent ledger edits are actually observed (today's collisions are
same-host) and (b) order 66 lands. Filing so the residual is not lost.

## Residual race note (already mitigated in-script)

During implementation a TOCTOU was found and fixed: a claimant that loses the
`mkdir` race must treat a *missing holder file* as LIVE, not stale — otherwise
it reclaims and destroys the winner's lease in the window between the winner's
`mkdir` and its `write_holder`. Mitigation: missing-holder ⇒ live; orphaned dirs
(process killed mid-claim) are reclaimed only via the lease dir's mtime once
aged past the TTL. 20/20 concurrency trials confirm the single-winner property.
The reclaim-after-expiry path still has a benign last-writer-wins race (two
claimants may both observe the same expired lease); resolved harmlessly because
only one `mkdir` after `rm -rf` wins and the other falls through to `in-flight`.

## Smallest next action

When order 66 is green and a cross-host ledger collision is actually witnessed,
promote a packet to add a git-backed `claim` event option to
`scripts/claim-ledger-node.sh` (push a lease event; honor a live remote lease as
`in-flight`). Bind a cross-host concurrency litmus then.
