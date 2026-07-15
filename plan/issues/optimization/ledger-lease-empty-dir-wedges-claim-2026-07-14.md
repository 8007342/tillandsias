# claim-ledger-node.sh: an empty (metadata-less) lease dir wedges the node as in-flight forever

- Date: 2026-07-14
- Class: optimization (coordination tooling; silent work-blocker)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-14T19:04Z
- Pickup: linux

## Observed

`scripts/claim-ledger-node.sh claim host-guest-transport-macos` returned
`in-flight:` (exit 1) although no live agent held it. The lease dir
`/tmp/tillandsias-locks/ledger-nodes/host-guest-transport-macos.lease`
was EMPTY (zero metadata files inside) with mtime 2026-07-11 — three days
past the 4h TTL. With no timestamp file, the expiry/reclaim path never
fires, so a session that crashed between `mkdir` and metadata write wedges
the node for every future cycle on that host until someone hand-removes
the dir (this cycle did: `rmdir` then `claimed:`).

## Fix shape

Treat a lease dir with missing/unparseable metadata as corrupt-and-expired:
reclaim it (`reclaimed:` verdict) instead of reporting `in-flight`. Use the
dir's own mtime as the TTL fallback clock. Pin in the existing
`litmus:ledger-node-claim-shape` with a fixture: `mkdir` an empty
`<node>.lease`, run claim, expect `reclaimed:<node>` exit 0.
