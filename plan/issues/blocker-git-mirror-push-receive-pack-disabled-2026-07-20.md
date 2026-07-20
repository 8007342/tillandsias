# Blocker: git mirror rejects ALL pushes — order 423 disabled receive-pack before the authenticated smart-HTTP replacement (order 322) shipped

- Date: 2026-07-20
- Class: bug (regression / git-mirror transport) — release-blocking for v0.4
- Filed by: linux-forge-opencode-metaorch-20260720T0530Z (meta-orchestration v0.4 drain)
- Root order: order 423 (`a59cfb9d`, committed 2026-07-20T04:12Z) + Decision 4 path 1 in
  `plan/issues/git-mirror-architecture-decision-2026-07-19.md`. Intended replacement:
  order 322 rung E (authenticated smart HTTP). That replacement has NOT been deployed.
- Related: order 322 (authenticated smart HTTP push frontend), order 369/413/414/415
  (relay correctness), `git-mirror-relay-token-renewal`.

## Symptom (live, 2026-07-20)

Every `git push origin linux-next` from a forge now fails at the transport layer:

```
fatal: remote error: access denied or repository not exported: /tillandsias
```

The running `tillandsias-git` daemon (port 9418) serves `upload-pack` (fetches work —
the earlier v0.4 drain cycles' commits ARE on origin/linux-next), but refuses
`receive-pack`. A raw capability probe confirms:

```
printf '0032git-receive-pack /tillandsias\0...' | nc tillandsias-git 9418  ->  empty (refused)
```

Port 8080 (the Decision-4 authenticated smart-HTTP frontend) is CLOSED — it was never
deployed. So there is currently NO push path at all.

## Root cause

`images/git/entrypoint.sh` (order 423) starts the daemon as:

```bash
git daemon --reuseaddr --export-all --base-path=/srv/git --listen=0.0.0.0 --port=9418 &
```

without `--enable=receive-pack`. The synchronous relay (`pre-receive` hook ->
`tillandsias-relay-refs` -> `git push --atomic` to GitHub via Vault GitHub token) can
ONLY fire if the daemon accepts the client push. With receive-pack disabled, the hook
never runs, so the relay is dead and no forge can push.

Order 423 shipped the *removal* half of Decision 4 (close the anonymous write path)
but NOT the *replacement* half (authenticated smart HTTP, order 322). The decisions
explicitly frame the daemon's receive-pack as acceptable only "for a closed LAN
setting where everybody is friendly" and as a stopgap until smart HTTP lands. On the
enclave network `tillandsias-git` is an internal service (not internet-exposed), and
the pre-receive relay is the real authentication/credential boundary, so re-enabling
receive-pack is a safe interim restore of the pre-order-423 behavior.

Timeline evidence the regression is live and global:
- order 423 committed 04:12Z; mirror container rebuilt/restarted with the new entrypoint.
- Commits landing on origin/linux-next AFTER 04:12Z are plan/ledger edits and fixes
  that did not require a forge→mirror push, or landed via a path unaffected by this
  (e.g. the relay for in-flight sessions); no post-04:12Z client push has succeeded
  through the daemon.
- A probe from this forge session gets "repository not exported" on receive-pack.

## Impact on v0.4

The v0.4 release gate requires linux-next to be promotable to main (merge-to-main-and-release
skill). With pushes broken, no new work reaches origin/linux-next, so the v0.4 scope
cannot advance and the daily release cannot be cut. This blocks the entire v0.4 track,
not just this cycle's commit (`3bb4edae`, currently stranded 1 ahead / 4 behind after
rebase).

## Smallest next action (owner: operator / Tlatoāni)

Two options, operator chooses:

1. **Interim restore (recommended, unblocks immediately):** re-add
   `--enable=receive-pack` to the `git daemon` line in `images/git/entrypoint.sh`
   (restores exact pre-order-423 push behavior on the closed enclave LAN; the
   pre-receive relay remains the credential/auth boundary). Then rebuild + relaunch
   the `tillandsias-git` container so the running image picks up the change
   (order 422 freshness gate / order 445 REFRESH signal). This is reversible and does
   not touch the security intent — it re-opens only what order 423 closed prematurely.

2. **Proper fix (Decision 4 target):** deploy order 322 rung E — authenticated smart
   HTTP (e.g. `git-http-backend` behind an auth module / mTLS) on 8080 with per-container
   credentials, and point `lib-common.sh` `write_forge_gitconfig` push URL at it. Larger
   change; until it lands, option 1 is required or pushes stay dead.

Do NOT leave receive-pack disabled while order 322 is undeployed — that is a
transparent-push outage, not a security improvement.

## Verification after fix

- `git push origin linux-next` from a forge succeeds (relay fires, GitHub advances).
- `scripts/test-git-mirror-relay-verified-ack.sh` still 4/4 (relay hooks untouched).
- Receive-pack probe returns a capability advertisement instead of empty.
