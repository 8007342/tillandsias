# Dirty-start refusal has no resume path for the host's own claimed work

- Order: `833-fpe7`
- Filed: 2026-08-19, host `Tlatoanis-MacBook-Air` (macos, `osx-next`)
- Class: `enhancement`
- Related: order 540 (`check-opsx-generated-dirt.sh`), order 641-e2qa
  (stranded `in_progress`), order 672-bz7u (`expire-claims`)

## What happened

This cycle started dirty. Three tracked paths were modified and uncommitted:

```
 M build.sh
 M crates/tillandsias-headless/src/tray/mod.rs
 M scripts/local-ci.sh
```

Meta-orchestration Start Of Cycle step 3 says to treat every status-visible
dirty path as immutable sibling/operator work, refuse the cycle, and perform no
committable work. Applied literally, that was the verdict here.

It would have been the wrong one, and the evidence saying so was already on
disk:

- `HEAD` is `7fde0770d` — `claim(829-g4xf,831-wmn4): tlatoanis-macbook-air`,
  authored by **this host** at 2026-08-19T17:46:01Z.
- The two claim fragments in that commit set
  `cargo-test-workspace-stops-at-the-first-failing-target` (829-g4xf) and
  `default-cargo-test-never-compiles-tray-or-vsock-server` (831-wmn4) to
  `in_progress`, both with `summary: claimed for cycle 2026-08-19T17:40Z`.
- The dirty files' mtimes (18:06:38Z, 19:47:46Z) fall **after** that claim.
- The diff hunks name their own orders in their comments: "order 829-g4xf",
  "Order 831-wmn4".
- `scripts/check-stranded-in-progress.sh` reports `in_progress=2 stranded=2`,
  naming exactly those two orders.

So the dirt is not sibling work and not operator work. It is **this host's own
claimed work, complete but uncommitted**, left behind when the previous cycle
was interrupted between implementation and commit.

## Why the refusal degrades into a deadlock

The refusal is designed as a safety pause: stop, hand the condition to a human,
lose nothing. That holds when a human is watching. In the unattended loop this
skill actually runs in (`./repeat --prompt "Use the /meta-orchestration
skill"`), nothing clears the condition, so:

1. Every subsequent cycle re-reads the same dirty tree and refuses identically.
2. The finished work never lands. It survives only as long as the worktree does.
3. The two packets stay `in_progress`, invisible to `ready` queries **and** to
   burndown — the exact double-invisibility recorded in 641-e2qa.
4. `expire-claims` (672-bz7u) eventually releases the *claim* after 24h. It does
   nothing about the uncommitted *diff*, so the work is now unclaimed AND
   unlanded, and the next host to take the packet reimplements it from scratch.

That last step is 814-iyu7's duplicated-work shape arriving by a second route.
A safety pause that no cycle can discharge is not a pause; it is a permanent
stall that also launders finished work into lost work.

## The precedent this is missing

Order 540 already solved this shape once. Launch-generated opsx/openspec
artifacts dirtied every forge checkout, and the fix was not to relax the
refusal — it was `scripts/check-opsx-generated-dirt.sh`, a deterministic
detector that classifies one known dirt class as intended project content and
prints one line from a falsifiable grammar
(`^(ok:opsx-only|ok:clean-tree|non-opsx:.*)$`). On `ok:opsx-only` the cycle
commits the set and re-anchors with the guard's `re-snapshot` mode; on
`non-opsx:` it falls through to the refusal unchanged.

What is missing is the analogous detector for the second known dirt class:
this host's own in-flight claimed work.

## Proposed reduction (`ready` packet)

`scripts/check-resumable-claim-dirt.sh`, printing exactly one line matching:

```
^(resumable:[0-9]+-[a-z0-9]+(,[0-9]+-[a-z0-9]+)*|ok:clean-tree|unattributable:.*)$
```

Exit 0 only when **all** of these hold:

- every status-visible dirty path is **tracked** (an untracked file is not
  attributable to a claim and must still refuse);
- the folded ledger reports at least one packet `in_progress` whose claim event
  carries `host:` equal to this host;
- every dirty path's mtime is **after** that claim event's timestamp;
- the claim is younger than the `expire-claims` TTL (an expired claim is not
  this cycle's to resume).

The verdict deliberately stops at `resumable:` — "safe for this cycle to
review and land" — not `auto-commit`. Proving that an edit *implements* the
packet it sits next to is an agent judgment, not a machine fact, and a detector
that claimed otherwise would be the order-531 shape: a truthful-sounding state
attached to the wrong artifact. What the detector removes is the deadlock, not
the review.

On `unattributable:*` the existing refusal applies verbatim. Nothing about
unknown dirt changes.

## Verifiable closure

- `litmus:resumable-claim-dirt-shape` pins the grammar and the exit codes.
- Fixture cases, each hermetic: clean tree; untracked file present (must
  refuse); dirty path older than the claim (must refuse); no live claim by this
  host (must refuse); claim past TTL (must refuse); the resumable case above
  (must pass, naming both orders).
- The negative controls are the point. A detector that only ever says
  `resumable:` is the deadlock with extra steps.

## Disposition this cycle

Resumed under the evidence listed above and landed as the completion of
829-g4xf and 831-wmn4, then the boundary was re-anchored with `re-snapshot` —
the same sequence order 540 sanctions for its own dirt class. The judgment call
is recorded here so the next reader sees that the refusal was overridden
deliberately, on named evidence, rather than skipped.
