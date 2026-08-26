# yoga dirty-start wedge — 642-fedr/776-cm74 implemented on disk, unlandable without operator disposition (2026-08-23)

- Date: 2026-08-23 (filed durably 2026-08-24T02:04Z, third refusal cycle)
- Class: blocker (operator disposition required)
- Area: meta-orchestration dirty-start refusal / resumable-claim detector / claim lifecycle
- Severity: high (finished work one claim-expiry away from being duplicated; merge debt growing every upstream cycle)
- Owner: operator (Tlatoāni) — both unblock paths below are operator-gated
- Discovered-by: yoga meta-orchestration cycles 2026-08-23T19:45Z, 21:50Z, 2026-08-24T02:00Z
- Status: resolved (work lost — superseded by 872-c9nd; see the closing note below)
- Filed-from: a clean temp clone at origin/linux-next `5c57275b1`. The wedged
  checkout itself may not be touched by a refusal cycle; the first two
  refusals reported only in session handoffs, which evaporated with their
  transcripts — this file exists so the third one does not.

## State of the wedged checkout (`/var/home/tlatoani/claudia/tillandsias`, yoga)

Branch `linux-next`, local HEAD `682f86d4c` (deliberately left behind origin —
a merge could rewrite dirty paths). 16 modified + 1 untracked path, all mtimes
2026-08-23T16:26–17:17Z, postdating yoga's pushed claim commit `394aa2d50`
"claim(642-fedr,776-cm74): yoga" (16:20:12Z):

- `642-fedr` (lww-channel-naming-obscures-field-correction):
  `crates/tillandsias-plan/src/fragments.rs`, `crates/tillandsias-plan/src/main.rs`,
  `scripts/check-fragment-status-loss.sh`, `plan/index.d/README.md`,
  `cheatsheets/concurrent-git/crdt-ledger-fragments.md`,
  `openspec/litmus-bindings.yaml`, and the UNTRACKED
  `openspec/litmus-tests/litmus-lww-fields-channel-alias-shape.yaml`.
  The `litmus-bindings.yaml` diff adds exactly the binding for the untracked
  litmus file — the tracked dirt references the untracked file.
- `776-cm74` (hash-image-sources-git-normalized):
  `scripts/hash-image-sources.sh`, `scripts/test-hash-image-sources.sh`.
- Gate side effect, not work (the 643-64bx blast radius): `VERSION`,
  `Cargo.lock`, `crates/{tillandsias-core,tillandsias-headless,tillandsias-podman,tillandsias-scanner}/Cargo.toml`.
- `plan/index.yaml`: local ledger edit from the interrupted cycle.

## Why three cycles refused it (and were right to, as written)

`scripts/check-resumable-claim-dirt.sh` returns
`unattributable:untracked-paths:openspec/litmus-tests/litmus-lww-fields-channel-alias-shape.yaml`
— condition 1, untracked dirt is never claim dirt, by design. The order-833-fpe7
resumable licence therefore cannot bless the tree, and the skill routes any
`unattributable:` verdict to the dirty-start refusal exactly as written. All
three refusal cycles verified the 17 paths byte-identical to their startup
boundary snapshots; nothing has drifted. Do NOT `git add` the untracked file to
flip the verdict — that games the guard.

## Why this is urgent, and getting worse

1. **Claim expiry.** Both claims were made 2026-08-23T16:20:12Z with a 24h TTL.
   The note events filed alongside this issue
   (`plan/index.d/20260824t020411z-642-fedr-776-cm74-wedge-record-yoga.yaml`)
   refresh yoga's activity and carry DO-NOT-RE-IMPLEMENT warnings, but if the
   lease ever lapses the rows return to the pool and another host duplicates
   ~4h of finished work (the 814-iyu7 shape, arriving via 833-fpe7's
   "expire-claims launders finished work into lost work").
2. **Merge debt grows every upstream cycle.** Since the wedge began,
   origin/linux-next has landed changes to FOUR of the dirty paths —
   `crates/tillandsias-plan/src/fragments.rs`, `crates/tillandsias-plan/src/main.rs`,
   `plan/index.yaml`, `scripts/check-fragment-status-loss.sh` (lenovinha's
   866-pvsx `fdd403d5c`, 846-idhn `0d576667d`, macuahuitl's 864-v8kr
   `ec63d18a2`). The eventual land of 642-fedr is already a real merge and gets
   harder the longer disposition waits.

## Unblock paths (operator action, smallest first)

(a) **Relaunch the loop on yoga with a prompt that names the dirt resumable.**
    Verbatim suggestion:

    > Use the ./skills/meta-orchestration skill. The dirty worktree in
    > /var/home/tlatoani/claudia/tillandsias is resumable 642-fedr/776-cm74
    > claim work from yoga's interrupted 2026-08-23T16:20Z cycle, untracked
    > litmus file included — review and land it per the order-540/833-fpe7
    > sequence.

    The agent then reviews the diff against each packet, lands it as its own
    commits citing the orders, merges origin/linux-next, and re-anchors the
    boundary — the sequence order 540 sanctions.

(b) **Extend the detector** so an untracked path REFERENCED BY a tracked
    claim-dirt addition (here: the litmus binding added in
    `openspec/litmus-bindings.yaml` names the untracked litmus file exactly)
    attributes to the same claim. Guard-loosening, so Tlatoāni-gated; would
    unwedge this class permanently.

## What this refusal cycle did NOT do

No worktree path touched, no merge into the wedged checkout, no `git add` of
the untracked file, no claim released. The wedged checkout is byte-identical
to its 2026-08-23T19:45Z state (boundary-guard verified each cycle).

## RESOLUTION 2026-08-24T18:56Z — the work was destroyed, not landed (872-c9nd)

The operator relaunched yoga with unblock path (a)'s verbatim prompt. Acting on
it found nothing to act on: `git status --porcelain --untracked-files=all` is
empty, `git stash list` is empty, and the reflog's sole entry before that
cycle is

    0bba6525f HEAD@{2026-08-23 23:09:38 -0700}: clone: from https://github.com/8007342/tillandsias.git

The checkout directory's mtime agrees. The wedged worktree was replaced by a
fresh clone at 2026-08-24T06:09Z — about four hours after this file was written.

Searched before concluding: `openspec/litmus-tests/litmus-lww-fields-channel-alias-shape.yaml`
appears in no commit on any branch, nowhere under /var/home/tlatoani, and there
is no backup beside the checkout. `git fsck` reports only this cycle's own
rebase objects. The 16 modified paths are back at origin state. **The work is
unrecoverable; 642-fedr and 776-cm74 must be re-implemented from scratch.**

Status: this issue is closed as **work lost**. The refusal cycles were correct
and the boundary guard verified the paths byte-identical every time — it
protected a directory that something else then deleted wholesale. The gap it
exposes is that a refusal preserved a *description* of the diff across three
increasingly detailed cycles and never preserved the diff. Carried forward as
872-c9nd, along with the still-open merits of unblock path (b).
