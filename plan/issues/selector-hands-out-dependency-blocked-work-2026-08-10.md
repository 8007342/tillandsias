# The batch selector hands out dependency-blocked and leased work (660-z774)

- Date: 2026-08-10
- Host: windows (windows-next), meta-orchestration cycle 12
- Class: `optimization/` — wasted cycles, found by trying to do the work
- Related: `632-39p3` (introduced `--claimable-by`), `626-*` (the selector)

## How it surfaced

The cycle took `248 spec-cheatsheet-contradiction-audit` from its own batch,
claimed it, and read the packet:

```
depends_on: [network-architecture-audit, credential-secrets-architecture-audit,
             proxy-git-mirror-configuration-audit]     # = 245, 246, 247
```

All three are `ready` — unstarted — and **all three were in the same batch**.
So the selector offered a packet together with the three packets blocking it.

`tillandsias-plan next windows` does not list 248 at all. Every entry it returns
carries `deps clear, unleased`.

## The cause is in the script's own header

`select-work-batch.sh` opens by describing what it is not:

> `tillandsias-plan next <role>` already answers "what is claimable?"
> correctly: release-aware, role-compatible, **dependency-clear, unleased**,
> priority-ranked. What it does not answer is "what should ONE cycle take?"

That is true and the division of labour is right. But the script then builds its
candidate pool from `query --status ready --claimable-by`, which applies
**none** of the four properties it just credited to `next`. It filters status,
role and release; dependency-clearing and lease-checking are simply absent.

So the layer that was supposed to add *cohesion on top of* claimability instead
**replaced** claimability with a weaker test.

Two consequences, both silent:

- **Blocked work.** A packet whose dependencies are unmet can fill a batch slot.
  Worst case is 248: three of its blockers occupied the other slots.
- **Leased work.** `query` does not check leases, so a batch can hand this host a
  packet another host is actively working. The lease mechanism
  (`claim-ledger-node.sh`) exists precisely to prevent that duplication, and the
  selector routes around it.

## Why it was invisible until now

The selector only started producing usable batches on this host a few hours ago
(632-retq, 643-bnag). Before that it refused on every invocation, so nothing
downstream of the query had ever been exercised here. On Linux the effect is
diluted: with 131 role-matching packets, a blocked one in a slot is a small
percentage and reads as an odd pick rather than a defect.

## Suggested fix

Intersect the candidate pool with `next <role>`'s eligible set before scoring,
or teach `query` the same `--deps-clear` / `--unleased` constraints and pass
them. The scoring, entropy and budget logic are unaffected — this is purely
about which packets are allowed into the pool.

A litmus is cheap and two-sided: assert that no packet in a batch has an unmet
`depends_on`, and that a packet with a live lease held by another host never
appears.

## Not fixed here

`select-work-batch.sh` is under active concurrent edit by the linux lane (it
changed three times in the last six hours: `--claimable-by`, release scoping,
the entropy floor, and the order-645 urgent override). Landing a pool change
from this host in the same window is how merge conflicts and double-fixes
happen. Filed with the evidence and the exact call site instead.
