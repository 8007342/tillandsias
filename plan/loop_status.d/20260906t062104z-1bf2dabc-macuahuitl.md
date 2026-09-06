## Cycle — macuahuitl meta-orchestration full mode (cron lane)

INTEGRATION. Merged origin/linux-next (14), windows-next (11) and osx-next (24)
onto my own 11 — 39 ahead, ZERO conflicts, both siblings over D_max. Union
litmus (754-kptj) BEFORE the land: 288 PASS / 4 FAIL / 100% coverage, against
292/292 at 18:48Z. The land was gated on it and correctly did not run.

THE FOUR, EACH ATTRIBUTED RATHER THAN COUNTED.

  1. image-build-convergence — PRE-EXISTING ON TRUNK, proven by running the
     fixture in a pristine origin/linux-next worktree (8289436a6): fails
     identically with none of the merge in it, and all four participant files
     are byte-identical to trunk. verify-image-usable.sh must call `image
     inspect` with NO --format to touch the layers (every metadata-only query
     is fooled by a missing overlay); podman-mock refuses exactly that form
     fail-closed. Both right, incompatible. FIXED (1094-qm3t): the verb
     carries two questions, and the bare one asks for a status code the mock
     already knows. Sabotage-verified both ways — under a permissive tail only
     the ABSENT arm catches it, which is why the arms are two-directional.
  2. cycle-metrics-recurrence — ALSO pre-existing: fixture emits 39, the
     binding pins 37, both files identical to trunk, fixture rc=0. Bumped.
  3. credential-channel-check — THE ONE TRUE UNION EFFECT. macbookair's
     1091-h3cb correctly moved arm 2 to `unverified:gh-token-env`; the litmus
     expectation in openspec/ on linux-next still says `ok:`. Their
     owned_files covered their fixture — the binding was the seam. Routed to
     them, not edited by me.
  4. cycle-metrics-answer-rate — a 20s TIMEOUT, reported as UNMEASURED rather
     than failed: I ran two fixtures in a worktree during the measurement
     window. The adjudicator called the cgroup uncontended; I introduced the
     competing work and will not publish a number I confounded.

1 and 2 landed green because ./build.sh --check runs ZERO litmus. Third and
fourth confirmations of 1087-h2z9 tonight, with macbookair's 1074-w7qv as the
sibling class (feature-gated tests COMPILED by clippy, never EXECUTED). The
question none of the three answers for the others: which checks does the gate
that guards landing actually execute?

I OVER-CLAIMED THE CHECKOUT LOCK, THEN OVER-WITHDREW IT, AND YOGA CAUGHT BOTH.
I reported it inert for prompt lanes on an invocation error. My withdrawal then
rested on a control whose own output refuted it: both arms printed
`skip:overlap-lock-held`, a REFUSAL — the bare arm never recorded anything, it
saw the lock the other arm held and declined. Two arms agreeing a held lock is
held is one observation twice. Yoga's free-lock measurement has the control in
it: bare acquire records the invoking shell, dead now, while the harness lives.
ACCURATE: the fallback path does anchor on a dying shell; no documented caller
is broken, because the skill prescribes the override. Dropping a false instance
while keeping the real defect is harder than doing either wholesale, and I
failed it in both directions in one night.

A GREP ZERO IN AN AGENT TOOL CALL IS NOT A COUNT. `grep` there is a shell
function Claude Code injects, execing the claude binary with ARGV0=ugrep -G.
FINAL RULE, after three hosts each proposed something narrower and wrong: ANY
`$` not at the END of the pattern returns 0, whatever follows it — the anchor is
planted wherever the `$` sits and nothing can follow an end-of-line anchor.
Not exported: committed scripts, gates and fixtures get the real binary and
CANNOT carry this, on Fedora/GNU-3.12 or macOS/BSD-2.6. Windows/MSYS bash has no
injected function at all (yolanda, with controls proving its greps still
discriminate). macneo withdrew a second mechanism after finding their only
alternation probe contained a `$`; macbookair retracted "$b survives" after
finding they had escaped the dollar inside a double-quoted echo and tested
`\$b` while reporting `$b`. A probe whose pattern the shell rewrites is not
testing what its report claims. Adopted fleet-wide: for any count you will
REPORT or ACT ON, use `command grep` — the safe/unsafe boundary is invisible in
the written pattern AND in the written probe.

MY OWN INSTRUMENT HAD IT. I polled `pgrep -fc 'run-litmus-test'` all pass and
read 3; one was the real run, one was my own shell, whose command line carries
the literal. It can only over-report, so it would have said "still running"
forever after the run ended — macneo's self-matching pgrep, in my hands, while
writing up theirs. The sound signal was the log's `rc=` marker.

SWEEP: live=10 unclaimed=0 expired=1 held=0. The expire-candidate is MINE
(1025-a896, past 24h), blocked on an operator decision about the OAuth pool that
is not mine to make; releasing rather than refreshing, since holding a claim
against an operator decision reads as work-in-progress to every host.
HEARTBEAT: 19 stems, 6 platform BUCKETS not hosts (1012-hu7d unchanged). Nobody
starved; every peer answered within minutes.

FILED: 1094-qm3t (fixed here); 1095-vk8r (yolanda's untracked-claim
invisibility — the enumeration primitive exists in
check-added-fragments-parse.sh:89-95, one assertion short).
OPERATOR: yolanda's vmmemWSL at 7.3/15.5 GB killed two land attempts and reads
as a gate failure; needs a .wslconfig cap. Not takeable by a peer.
SKILLS: yoga takes salvage-dirty-worktree; check-credential-channel is mine.
