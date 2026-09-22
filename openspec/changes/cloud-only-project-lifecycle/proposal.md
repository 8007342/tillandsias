# Cloud-only project lifecycle: no local checkout, one remote list, the mirror as the only source

## Why

The operator's direction, given on 2026-09-21 and routed to the coordinator for
the spec: *"There should be no local list at all. Only cloud list, always
remote. Every checkout goes away on containers close. Fix the cloud listing."*
And, on the question of testing an uncommitted change in a forge: *"There
should be git-mirror configured allowing work/ branches without test passes …
the local checkout removal, and how the cloud only menu should behave
idempotent, always from remote, and how the git-mirror changes (recently
overhauled by lenovinha-silverblue) should make for a sound and complete spec
and implementation."*

Three threads exist as separate rows and have aged separately: the host `~/src`
bind-mount into forges (591-x7ws, filed 2026-08-02, ready for seven weeks), the
tray's cloud project list (591-33s6, in flight; 997-e4v2's dead local-list
scaffolding), and the git mirror's credential-free push lane (1313-prin
accepted on two regimes; the in-stack forge design 1340-tzsx audited). They are
one design: a project exists for Tillandsias only as a remote repository; the
enclave's git mirror is the only source a forge ever checks out from and the
only thing a forge ever pushes to; the tray's project list is the remote list
rendered idempotently; and a checkout lives exactly as long as the container
that made it.

## What changes

- **No host checkout reaches a forge.** `TILLANDSIAS_PROJECT_HOST_MOUNT` and
  the opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` live-edit path are retired —
  removed, not left unused. Every forge checks out from the mirror into its own
  container filesystem, and that checkout goes away when the container closes.
- **The way to test an uncommitted change in a forge is a ref, not a mount.**
  The dirty tree becomes a `work/<order>` or `salvage/<host>/…` ref through the
  existing plumbing (`scripts/salvage-dirty-worktree.sh` touches nothing in the
  worktree), the mirror accepts it with no gate (its receive hardening refuses
  only deletions and refs outside `refs/*`), and the forge is seeded from it
  (`TILLANDSIAS_FORGE_SEED_BRANCH`, which already tolerates any ref). This
  replaces the bind-mount's affordance and is named where a worker looks for it.
- **The mirror's exported heads track upstream.** Today they move only at
  startup and when a push passes through the relay, so a ref pushed to GitHub
  from a bare-metal host is invisible to a forge until someone else pushes
  through that mirror (measured 2026-09-21: three commits behind for minutes,
  1338-tkfh). Exported heads SHALL fast-forward to upstream on demand and on a
  cadence, never clobbering a locally stranded commit, and the sync state SHALL
  be observable from inside a forge.
- **The relay records who pushed.** Principal, certificate serial and key id
  per ref transaction (1340-tzsx audit amendment A5).
- **The tray's project list is the remote list only,** rendered idempotently
  from remote state, paged when it overflows, with no local-projects section,
  no `~/src` scanner feeding it, and no mirror-to-host working-copy sync.

## What does not change

- The mirror's reconcile rule that upstream never clobbers exported refs
  (req 85f3a329) stands; tracking is fast-forward only.
- The ssh push lane's authorisation model (sshd's principals file; one
  principal per client class) and the credential-free host and forge halves
  stand as accepted and audited.
- The forge's isolation contract (no `$HOME` bind-mounts) stands and gets
  simpler: the one exception it carried is gone.

## Rows this change unifies

591-x7ws (host mount removal), 591-33s6 and 997-e4v2 (cloud list), 1313-prin
and 1340-tzsx (mirror lane and in-stack design), 1338-tkfh (mirror lag
observable), 1337-3tk6 (host attribution). Their exit criteria are restated in
`tasks.md` as ordered tasks; the rows remain the units of claim and closure.

## Operator decisions (2026-09-22)

Both readings below were put to the operator as vetoable and CONFIRMED on
2026-09-22: *"Yes on the cloud only, remove the host checkout remainders."*

1. The opt-in `TILLANDSIAS_FORGE_HOST_MOUNT=1` live-edit path is retired along
   with the project host mount — read from "every checkout goes away on
   container close" and from the answer that work/ branches through the mirror
   are the way to test a change.
2. The mirror-to-host working-copy auto-sync and the `~/src` scanner are
   retired — read from "always remote": with no local list and no host checkout
   the tray has nothing on the host to keep current.

T5 and T6 in `tasks.md` are therefore decided, not provisional; every remainder
of the host checkout (the two mount variables, the scanner, the sync, their
cheatsheets and staged copies) is to be removed in the ordered tasks.
