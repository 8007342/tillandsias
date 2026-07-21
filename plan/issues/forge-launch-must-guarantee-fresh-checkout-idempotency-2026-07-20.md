# A forge launch must GUARANTEE a valid, current checkout — non-idempotent launch left an agent with no checkout (2026-07-20)

- **Class**: bug (idempotency / ephemerality violation) — operator-stated invariant
- **Severity**: P1 — an agent launched onto an empty/missing checkout cannot work;
  same "works, reports success, isn't doing the thing" class the operator keeps hitting
- **Found**: live, 2026-07-20 attended session
- **Specs**: remote-projects, forge-hot-cold-split, tray-ux
- **Owner host**: linux
- **Related**: order 437 (clone-only forges — "no circumstances on which an agent
  lands on a DIRTY forge"; this is the sibling invariant: no circumstances on
  which an agent lands on a forge with NO checkout), order 342 (src-isolation
  read-only staging), the concurrent-forge shared-stack bounce packet
  (2026-07-20), order 425 (fail-loud on absent index).

## Operator requirement (2026-07-20)

> A fresh launch of claude had no checkout either. I deleted the local src
> checkout before launching the agent, to ensure a checkout, but the binary
> probably thought that the old checkout was still there, which breaks our
> principles of idempotency. If I click on the cloud icon then there has to be a
> checkout. Idempotency and Ephemerality at every step.

The invariant: **every forge launch must guarantee the agent lands on a valid,
current checkout** — verify ground truth, materialize fresh if missing/invalid/
stale, and FAIL LOUD rather than start an agent on an empty tree. A cached belief
that "the checkout is already there" must never substitute for checking.

## Observed

- Operator deleted `/home/tlatoani/src/tillandsias`, launched a Claude forge via
  the tray cloud icon.
- The launched forge had NO checkout.
- `/home/tlatoani/src/tillandsias` now exists again but pinned at a STALE commit
  (`7914f2ea`, v0.3.260719.1) — not latest — i.e. even when a checkout is
  present, the launch does not bring it current.

## Root-cause surface (non-idempotent "assume exists" checks)

Both cloud-clone entry points gate the clone on mere directory existence, not on
the checkout being a VALID, CURRENT git worktree:

- `handle_launch_cloud_project` (crates/tillandsias-headless/src/tray/mod.rs
  ~2249): `if !target_path.exists() { clone } else { best-effort git fetch }`.
  A path that exists but is a partial / empty / wrong-remote / stale checkout is
  accepted; `git fetch` updates remote-tracking refs but never fast-forwards or
  resets the WORKING TREE, so the tree stays stale.
- `resolve_cloud_project_checkout` (crates/tillandsias-headless/src/main.rs
  ~3673): same `if !target.exists()` gate.
- (To confirm) how the clone-only (order 437) MIRROR bare repo is seeded, and
  whether an "ensure-if-healthy / don't --replace a running mirror" guard skips
  re-seeding so the forge clones stale/empty content over git://.
- (To confirm) whether the forge entrypoint's `clone_project_from_mirror`
  (images/default/lib-common.sh) FAILS LOUD when it produces an empty working
  tree, or silently drops the agent into an empty dir.

## The fix (design + verifiable closure)

At the single launch chokepoint that finalizes the project path before the forge
container starts, enforce a ground-truth contract:

1. **Validate the source is a real, current checkout** — exists AND is a git
   worktree AND has the expected remote AND (for cloud projects) its working tree
   is fast-forwarded to the resolved upstream head. Not just `path.exists()`.
2. **Materialize fresh on any failure** — missing/partial/wrong/stale → clone or
   hard-reset to the resolved head (ephemeral working tree, order 437 makes this
   cheap). Idempotent: repeated launches converge to the same valid state.
3. **Fail loud** — if a valid checkout cannot be produced, refuse the launch with
   an actionable tray/CLI message; NEVER start an agent on an empty/stale tree.
4. **Clone-only mirror**: ensure the mirror's served content reflects the current
   upstream/host head at launch (re-seed / fast-forward the bare repo even when
   the mirror container is already healthy), so the forge's git:// clone is current.

Verifiable closure (fail-loud fixtures, reproduce the break first):

1. A fixture that points the launch at a DELETED path and asserts the launch
   materializes a valid checkout (not an empty dir) — reproduce the empty-forge
   break first.
2. A fixture that points the launch at a STALE checkout (behind upstream) and
   asserts the working tree is brought current (not left behind).
3. A fixture that makes materialization impossible and asserts the launch
   FAILS LOUD (no silent empty-tree start).

## Non-goals

Do not reintroduce the host-mount gitdir facade. Do not weaken order 437
clone-only isolation. This is about GUARANTEEING content, not about sharing the
host tree.
