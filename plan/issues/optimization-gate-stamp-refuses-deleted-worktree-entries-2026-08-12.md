# optimization: `gate-stamp write` refuses any worktree containing DELETIONS, so ledger compaction always costs a second full gate run

- **Filed**: 2026-08-12
- **Host**: macos (Tlatoani's MacBook Air)
- **Class**: `optimization/` (Reduction Engine capture: "explicitly log things
  that make you slower")
- **Order**: 695-nvnd
- **Status**: open

## What happened

During a normal meta-orchestration cycle:

1. `tillandsias-plan fragments` reported `eligible=true fragments=41`, so the
   cycle compacted — which by design **deletes the 41 folded fragment files**.
2. `./build.sh --check` then ran to completion and **every check passed**.
3. The stamp step nonetheless emitted:
   `Could not record gate stamp — pre-push may ask you to re-run the gate`.
4. Run directly, the cause is explicit:

```
$ bash scripts/gate-stamp.sh write
gate-stamp: unsupported worktree entry: plan/index.d/20260811t081200z-682-ym68-done-linux-mutable.yaml
stale:cannot-write-stamp
```

That path is one of the fragments compaction had just deleted. `gate-stamp`
classifies worktree entries and has no case for a **deletion**, so it refuses to
stamp a tree that is otherwise green.

## Why it costs time

The gate is the trunk's only protection, and the pre-push hook requires a stamp
matching the exact tree being pushed. So the sequence a compacting cycle is
forced into is:

- run the full gate (minutes) → passes → **no stamp**
- commit the compaction
- run the full gate **again** on the now-clean tree → passes → stamp
- push

Compaction ALWAYS deletes fragments — that is what compaction is — so **every
cycle that compacts pays the full gate twice**. On this host `build.sh --check`
is the single slowest step in the cycle (the `timing:` metric exists precisely to
surface that), so this roughly doubles the cycle's dominant cost whenever the
ledger is due for GC.

It also produces a misleading operator experience: a completely green gate
reports a warning that reads like flakiness, and the natural response ("just
re-run it") is in fact the only thing that works — for a reason nothing on
screen explains.

## Smallest next action

Teach `scripts/gate-stamp.sh` to accept deleted entries. A deletion cannot
invalidate a stamp the way an unstaged modification can: the content that was
checked is gone, not different, and the gate's own checks (ledger integrity,
fragment status-loss) already ran against the post-deletion tree. Treat a
`D`/` D` status entry as stampable rather than `unsupported`.

Verifiable closure: a test that stamps a worktree whose only dirt is a deleted
tracked file and asserts a stamp is written — plus a **negative control** that a
worktree with a MODIFIED tracked file is still refused, so the fix cannot
degrade into "stamp anything" (bar-raise 634-39ik).

## Notes for whoever picks this up

- Do not "fix" this by making the cycle skip compaction. Compaction is garbage
  collection on an append-only ledger and skipping it is how `fragments=41`
  became normal in the first place.
- Do not fix it by stamping before the deletions. The stamp must describe the
  tree that gets pushed; stamping an earlier tree is exactly the breach class
  the stamp exists to prevent.
