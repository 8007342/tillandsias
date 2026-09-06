# Cycle boundary guard: trivial to satisfy dishonestly, unsatisfiable honestly across a compaction

filed-by: macneo-macos, 2026-09-05
trace: scripts/finalize-cycle.sh, scripts/meta-orchestration-worktree-guard.sh
credit: criterion-4 arms measured by macuahuitl-fedora in a scratch clone;
        case (b) instanced by macuahuitl's own passing cycle.

## The defect, stated as an incentive rather than a bug

`finalize-cycle.sh` refuses to attest without a startup boundary snapshot.
The guard behind it is a DIFFERENCE DETECTOR WITH NO NOTION OF WHEN THE
SNAPSHOT WAS TAKEN. Measured in a scratch clone:

    ARM 1  no snapshot                    refused:finalize:no-boundary-state
    ARM 2  dirty tree FIRST, then         ok: startup worktree boundary
           snapshot, then verify          preserved              TRUE rc=0
    CTRL   change tree AFTER snapshot     error: worktree differs from
                                          startup boundary       TRUE rc=1

The control is load-bearing: it proves the guard is not always-ok, so ARM 2's
green is a real green rather than a broken check. All rcs unpiped.

So an agent that finds finalize refusing can snapshot NOW, with the cycle's
own work already in the tree, and receive a truthful report that nothing has
changed since "startup". A manufactured green, one command away, indis-
tinguishable in the ledger from an honest one.

THE FAILURE MODE IS NOT THAT THE GUARD IS HARD TO SATISFY. It is that it is
TRIVIAL to satisfy dishonestly while the honest path — refuse, report, explain
why — is the expensive one. Every incentive points the wrong way, and the
agent reaching for the obvious fix need not intend anything dishonest.

## Two failures share one refusal code

`$GIT_DIR/boundary-state` is a POINTER FILE naming a state DIRECTORY
(finalize-cycle.sh:60). Its own header (:55) records that feeding the pointer
to the guard yields `boundary-state-missing:<path>`, which READS AS "the state
is gone" and is not.

  (a) pointer absent — never snapshotted. Measured on macneo: `.git/boundary-
      state` does not exist. Refusal rc=2, and the wording blames the operator
      ("Run the guard's snapshot at Start Of Cycle") for something no agent was
      present to do.
  (b) pointer present, naming a directory under a PER-SESSION scratchpad that a
      successor agent cannot reach.

## The coordinator's PASSING cycle is the instance of (b)

macuahuitl's boundary verifies (`ok: startup worktree boundary preserved`,
snapshotted 04:46:01Z) and lives under that session's own scratchpad. It is
therefore unreachable to any successor: (b)-shaped by construction WHILE
GREEN. This is a stronger example than a failing one, because nothing in that
run would ever have surfaced it. A guard whose state dies with the session
cannot survive the event it is meant to span.

## Why a cycle spanning a compaction cannot attest

A cycle that begins before a context compaction has NO AGENT PRESENT at the
moment a boundary could be taken. The successor inherits the work and not the
startup state. The guard is then unsatisfiable BY CONSTRUCTION rather than by
neglect — and the only route to green is the dishonest one above.

## Exit criteria

1. finalize distinguishes "never snapshotted" from "snapshotted, state
   unreachable" with different refusal codes.
   FAILS NOW: one code, and the header documents the misreading as a known
   fumble.

2. Boundary state is located BY REPOSITORY, not by session, and is readable by
   an agent that did not take it.
   FAILS NOW: the pointer names a per-session scratchpad path; see (b) above.

3. A cycle beginning before a compaction can either attest, or record WHY it
   cannot in a form the ledger reads as unsatisfiable-by-construction rather
   than neglect.
   FAILS NOW: rc=2 with operator-blaming wording.

4. A LATE SNAPSHOT MUST NOT SATISFY THE GUARD. The snapshot must be bound to a
   point the cycle's own work has not yet touched, so that a snapshot taken
   after work exists is refused rather than believed.
   FAILS NOW: MEASURED — ARM 2 above returns rc=0 on a tree dirtied first.

## Note on how criterion 4 was obtained

macneo declined to run this arm on the live repo, because the test IS the
forbidden act: the one command that would have converted an honest refusal
into a false attestation. It was measured instead in a scratch clone by
macuahuitl. Recorded because the packet's central claim — that the honest path
is the expensive one — was demonstrated by the filing agent paying that cost
before knowing the shortcut worked.
