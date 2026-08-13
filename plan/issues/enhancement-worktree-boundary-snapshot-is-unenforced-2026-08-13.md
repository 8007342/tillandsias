# The worktree-boundary guard can be skipped, and skipping it looks like passing

Filed 2026-08-13 (windows host, meta-orchestration cycle 16→17). Filed against
myself: I skipped it, and the loop carried on.

## What happened

The meta-orchestration skill's Start Of Cycle says to snapshot the startup
worktree boundary before classifying or changing any path, and Finalization says
to run the guard's `verify` mode before exit. Cycle 16 did the second without
the first. `verify` answered:

```
error: state directory does not exist: /tmp/meta-orchestration-boundary.Wxg6hS
```

— the path from the PREVIOUS cycle, which had already been removed on its own
successful exit. Nothing else in the cycle noticed. The commit landed, the push
succeeded, and `scripts/mo-full-attest.sh self` printed a valid `MO-FULL:`
marker, because the marker attests that HEAD is durably on the remote, not that
the boundary was ever recorded.

No damage: the tree was clean at start and everything this cycle produced was
committed. That is luck plus a clean starting state, not the guard working.

## Why it is worth a packet

The guard exists for the case where the tree is NOT clean at start — sibling or
operator work that must survive the cycle byte-identical. In exactly that case,
a skipped snapshot is invisible: `verify` fails with a message about a missing
state directory rather than about the worktree, and an agent that reads it as
"stale temp path from last time" is reading it correctly. The failure mode is
therefore a guard that is silent about the thing it guards precisely when the
stakes are highest.

This is the same class the loop has been repairing all night, one level up:

* order 622-rmit — a guard only an attentive agent honors is a suggestion;
* order 716-f5kc — a Linux build compiling stubs and reporting success;
* order 632-retq — an environment fault reported as a drained ledger.

Each was fixed by making the tool answer a question rather than trusting a
convention. This one is still a convention.

## Candidate shapes, none decided

1. **Make the marker depend on it.** `scripts/mo-full-attest.sh self` already
   refuses to print unless HEAD converged on the remote. Adding "a boundary
   state dir exists and verified for THIS cycle" is one more precondition on the
   one command a full-mode cycle must run to finish. Strongest option, and it
   fails in the loud direction: no marker, which the outer gate already treats
   as failure.
2. **Have the guard create its own state.** `verify` with no prior snapshot
   could answer `blocked:no-snapshot-taken` instead of an errno-flavoured
   message about a missing directory — the difference between naming the
   process fault and describing a symptom.
3. **Leave it as a convention and accept the risk.** Defensible only if the
   dirty-start case is rare, and the record says otherwise: the skill devotes a
   whole section to it and names a specific breach (`4a1410a2`).

Option 1 is the one that matches how this project fixes things, but it changes
the terminal attestation contract, which is 614-2gqx's territory and deserves an
explicit decision rather than a passing edit at 06:30.

## Not fixed here

37 minutes remained in the loop's window when this was written. Starting a
change to the attestation contract with that budget would have produced exactly
the half-landed guard this note is about.
