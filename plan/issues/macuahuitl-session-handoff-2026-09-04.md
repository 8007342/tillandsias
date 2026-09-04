# macuahuitl session handoff — 2026-09-04 fleet restart

Written at the operator's shutdown notice. Read this before re-deriving anything.

## State at handoff

- `linux-next`, `windows-next`, `osx-next` all level. Worktree clean, nothing unpushed.
- Claim board clear: 0 live, 0 unclaimed, 0 expired.
- Daily maintenance gate stamped for 2026-09-04 (ran at 02:08Z: delegate sweep,
  nix gc under-ceiling, podman prune 60→58, capability row current, both nix-lane
  fixtures, nix-cache 8/8). Build-cache sweep NOT due — 17 GiB against a 40 GiB
  trigger, 2-day marker.
- **Session crons were `coordinate 23 0-22/2` and `meta 38 2-22/4` (LOCAL).
  They are session-scoped and die with this session. The next session must
  re-arm them, and re-arming is an OPERATOR decision on their machine's spend —
  ask, do not assume.**

## Operator queue — five plain asks, all still open

1. **Renew the esmeraldinha PAT.** Check EXPIRY first; the 2026-08-15 precedent
   was a lapsed token, not a wrong scope, and the two are indistinguishable from
   inside a forge. **Then re-run the login FROM A CHECKOUT WITH AN ORIGIN** —
   759-vceg's no-upstream arm seeds an unverified token, which is why the
   operator's login exited zero and the push stayed 403. Do NOT rebuild the git
   image for this.
2. **Permission for macneo to run a forge build** on the operator's Mac for the
   978-juw4 2 GiB measurement. Pegs the machine over an hour.
3. **Is macneo-macos still up?** ~18h silent, unanswered status ask.
4. **The root-vs-forge privilege call (996-bcjx).** yolanda established the
   per-launch migration dissolves the class — single writer, single reader — so
   this is now "which identity", not "should we patch it".
5. **The ten quarantined trees on esmeraldinha**, ~1.7 GB. esme verified zero
   unpushed commits and zero content diffs. Deletion is the operator's.

**yolanda separately carries two questions with THEIR operator** — the
architectural removal, and what happens to an existing `~/src` on an upgrading
host. Do NOT report their state; only they know it. That inference was made once
and corrected at 5e0427809.

## Things not to re-derive

- **`ready` now marks worked rows** `worked:<n>@<host>`. 309 of 422 carry
  history — half the queue reads unstarted and is not. Use it to pick dispatches.
- **`scripts/finalize-cycle.sh`** does the whole Finalization sequence in one
  command. It refuses on an uncommitted tree, a wrong internal order, and a red
  gate — all three exercised, none emitted a marker.
- **`scripts/dispatch-brief.sh <order>`** emits the head a brief was written
  against and marks a packet UNTOUCHED or WORKED. Use it before dispatching.
- **Do not `tail -1` a guard.** They print reasoning and remedy on stderr; the
  idiom discards it. Three distinct `ok:` arms of the credential guard were hit
  in one day and all were fully explained in the channel being thrown away.
- **`land-on-platform-branch.sh` merges when the unpushed set carries merge
  commits.** Rebasing there conflicts by construction (991-85bh).
- **The methodology expert is fine.** `methodology_ask` routes PROSE through
  eleven fixed forms; `methodology_path` takes paths. The refusal used to point
  at the wrong tool — fixed in 997-q8jm.

## The session's recurring defect, in one line

**A summary standing in for the artifact.** Eight instruments answered a
different question than the one asked of them, including three of my own where a
`grep -c` was reported as a verification. The counter is the cheap settling read,
run BEFORE asserting — three times it shrank the finding to nothing, and once it
removed the work entirely.

## Newest and hottest

**1000-rqmx, p1, filed minutes before shutdown.** An unpushable branch on a
fast-moving trunk becomes a weapon: esme's innocent one-file commit grew a diff
of 139 files and 5,096 deletions against the trunk. A naive retry loop would have
reverted all of it the moment the credential recovered. The real fix is the gate
refusing a push whose diff deletes files the outgoing commits never touched.
