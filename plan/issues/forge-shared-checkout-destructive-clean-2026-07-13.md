# P1: in-forge meta-orchestration on the macOS shared checkout git-cleaned sibling work it did not create

- Date: 2026-07-13
- Class: bugfix (agent-concurrency safety; data-loss hazard)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z (the near-victim)
- Related: order 321 (host/forge isolation, rung D), order 315 audit "host-shared (macOS virtiofs) vs mirror-materialized (Linux)", plan/issues/agent-concurrency-collisions-2026-06-20.md, skills/meta-orchestration "unknown user work: do not overwrite it; record a blocker"
- Pickup: linux (skill + forge lane are shared surfaces; macOS host reproduces)

## What happened (live, 2026-07-13T23:08Z, BigPickle in-forge on macOS)

The macOS `--opencode` forge lane mounts the HOST checkout into the forge
(virtiofs `~/src` → `/home/forge/src`; the forge project dir IS the
operator's working tree — unlike Linux, where the forge gets a fresh
mirror clone). BigPickle's meta-orchestration cycle, blocked on the
credential channel and enforcing its exit contract ("no local-only
commits", "leave a completely clean work state"), ran:

```
git checkout -- plan/index.yaml && git clean -fd plan/issues/
```

— discarding a sibling agent's (this host cycle's) uncommitted plan
packets: 5 issue files + plan/index.yaml edits. The work survived ONLY
because the host agent had committed and pushed (e84ba192) minutes
earlier, making the files tracked-at-HEAD; the `git clean -fd`
(untracked-only) and `checkout --` (restore-from-HEAD) became no-ops.
Had the race gone the other way, ~500 lines of filed findings were gone
irrecoverably.

Transcript evidence (host log target/build-install-smoke-e2e/
20260713T224400Z/04b-bigpickle-meta-orchestration.log):

> "The worktree has substantial uncommitted work from earlier today (new
> packets orders 323-325 in plan/index.yaml, 7 untracked issue files).
> This is all local-only and cannot be pushed due to the credential
> channel failure. Per the exit contract: no local-only commits allowed.
> The only clean option is to discard the uncommitted changes…"

It also reverted its OWN blocker-file update for the same reason —
self-erasing the only durable evidence its cycle produced.

## Why the skill text did not prevent this

The skill's dirty-worktree rule ("unknown user work: do not overwrite it;
record a blocker") applies at STARTUP; the exit contract's "leave a
completely clean work state" applies at EXIT and won in the agent's
reasoning. On a dedicated clone those rules are compatible; on a SHARED
working tree they are contradictory, and the contract's cleanliness
clause becomes a data-shredder.

## Fix directions

1. **Skill fix (immediate, text-only)**: exit contract must scope
   "discard temporary artifacts" to artifacts THE CYCLE CREATED. Files
   present before the cycle started (startup `git status` snapshot) are
   sibling/operator work: never `checkout --`/`clean` them; leave them and
   record a handoff note instead. Blocked cycles leave the tree exactly
   as found.
2. **Structural fix (order 321 adjacency)**: stop running in-forge cycles
   directly on the operator's shared checkout on macOS — materialize a
   forge-owned worktree (mirror clone or `git worktree` off the shared
   tree) so forge git state and host git state cannot collide. This is
   the same isolation boundary rung D wants for config; extend it to the
   working tree.

## Verifiable closure

- litmus: a fixture cycle started on a tree with pre-existing untracked
  files + tracked modifications, forced into the blocked path, exits
  leaving those files byte-identical (checksum before/after), with the
  blocker recorded.

## Reduction decision (2026-07-14)

The immediate safety repair is order 341, `forge-dirty-tree-exit-contract`:
dirty-start cycles are preflight refusals, automated finalization never
deletes or restores a worktree path, and a snapshot/verify guard checks every
status-visible startup path byte-for-byte. Disposable diagnostics live only in
the unique external boundary directory. Canonical skills, cheatsheets, and
cheatsheet sources now participate in the forge image cache key so a cached
image cannot retain an older destructive contract.

The structural macOS child is order 342,
`macos-forge-owned-checkout-isolation`. It MUST use an independent guest-owned
clone/materialization for unattended meta-orchestration, sourced and pushed
through the enclave mirror. A `git worktree` linked to the virtiofs host repo is
rejected: it still shares and mutates host `.git/worktrees`, refs, objects,
branch locks, and lifecycle state. `/home/forge/src/<project>` remains the
read-only source identity/input for unattended runs; normal interactive forge
editing behavior is outside this child. Live closure requires a current VZ run
over a dirty host checkout proving unchanged before/after hashes and successful
isolated-clone push convergence.
