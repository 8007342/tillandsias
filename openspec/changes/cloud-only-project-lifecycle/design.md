# Design notes

## The lifecycle, end to end

1. **Discovery** — the tray lists the repositories the seeded GitHub token can
   see (the remote list), cached per boot and refreshed on demand; the menu is
   a pure function of that list plus per-project running state.
2. **First launch** — selecting a project creates its bare mirror in the enclave
   (seeded once from upstream) and launches a forge that clones from the mirror
   over the anonymous `git://` daemon. Nothing on the host is read or written.
3. **Work** — the forge pushes through the ssh lane with its own certificate
   (`til:forge-push:<mid>`); a bare-metal host pushes through the same lane
   with `til:host-push:<host>`; the relay forwards to GitHub atomically and
   logs the pusher. `work/*` and `salvage/*` refs are accepted without a gate;
   `linux-next`, `main` and tags keep the gates the pre-push hook applies on
   the pusher's side.
4. **Sync** — the mirror's exported heads fast-forward to upstream on demand
   (a tray action and a CLI verb) and on a cadence, so a ref pushed to GitHub
   from anywhere becomes seedable inside the enclave within a bounded time; a
   forge can ask the mirror when it last synced and whether a named ref is
   "behind upstream" or "absent upstream" — two different answers.
5. **Close** — the container's filesystem, and the checkout with it, is gone;
   the mirror keeps every ref that was pushed; the next launch seeds from
   whatever ref the user names.

## Testing an uncommitted change (the affordance the mount used to give)

    scripts/salvage-dirty-worktree.sh <slug>       # ok:salvaged:<ref>:<sha>, worktree untouched
    tillandsias --sync <project>                    # exported heads fast-forward from upstream (if the ref went to GitHub)
    TILLANDSIAS_FORGE_SEED_BRANCH=<ref> tillandsias --claude <project>

A bare-metal host with the lane on skips the middle step: its push lands on the
mirror directly. The skill for joining the fleet and the forge welcome name this
sequence, so the workflow does not stop existing quietly.

## Why the sync is on demand AND on a cadence

On demand answers the developer who just pushed a ref and wants to seed from it
now. The cadence answers the forge whose plan-only push loses the race against a
trunk that moved on GitHub (the relay's staleness guard refuses a stale old-id,
and a forge cannot refetch GitHub the way a bare-metal host can); it bounds how
far behind a forge's base can be. The cadence is a number the mirror reports,
not a constant a reader has to know.

## What is deliberately not in this change

- Any change to the pusher-side gates (the pre-push hook's lanes).
- The T11 default flip of the forge lane; it waits on a forge acceptance.
- Windows credential isolation for the mirror (its own change).
