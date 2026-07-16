# P1: macOS clone lane (order 342) — in-forge push URL falls back to the read-only staged checkout

- Date: 2026-07-16
- Class: bugfix (in-forge cycle blocking on macOS; sibling of order 382's WSL2 finding)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-16T07:31Z (source analysis, not yet live-reproduced)
- Related: order 342 (adc488d8, clone isolation), order 382 (dd34cd8a, Hy3/WSL2 root-owned staged gitdir), images/default/lib-common.sh `clone_project_from_mirror` filesystem transport, plan/issues/macos-forge-gitdir-facade-guest-git-missing-2026-07-15.md
- Goal context: BigPickle/Hy3 in-forge /meta-orchestration on macOS cannot complete its exit contract (push) through this path.

## Analysis

Order 342 wires the macOS `--opencode` lane as
`TILLANDSIAS_GIT_MIRROR_PATH=/home/forge/src-host/<project>` (the operator
checkout staged READ-ONLY), and the entrypoint's filesystem transport
clones it into the ephemeral working tree. Then, for remote alignment,
`lib-common.sh` runs:

    mirror_origin="$(GIT_DIR="${src}" git config remote.origin.url ...)"

For the Windows/WSL2 case `src` is a BARE mirror, so `GIT_DIR=$src` works.
On the macOS lane `src` is a NON-BARE working checkout root — git reads
`$GIT_DIR/config` = `<checkout>/config`, which does not exist → empty →
`github_url` empty → fallback branch executes:

    git remote set-url --push origin "${src}"

so every in-forge `git push` targets the READ-ONLY staged mount (and a
non-bare repo's checked-out branch besides): push always fails. No mirror
redirect exists either, because the guest-side `write_forge_gitconfig`
insteadOf rewrite is separately dead (guest OS has no git —
macos-forge-gitdir-facade-guest-git-missing-2026-07-15.md).

## Smallest shaped fix (owner: entrypoint/lib-common seam, linux canonical)

In the filesystem transport, resolve the origin URL in a gitdir-agnostic
way: `git -C "${src}" config --get remote.origin.url` (works for bare and
non-bare; `-C` resolves the gitdir itself). Keep the token-stripping and
insteadOf routing exactly as-is. A one-line change makes the macOS clone
lane's push route to the staged checkout's real GitHub origin *rewritten
through the local mirror* once the mirror-side rewrite works — and in the
interim produces an honest "cannot push: no mirror" instead of a silent
push to an RO path.

## Verifiable closure

- Fixture: run `clone_project_from_mirror` with `TILLANDSIAS_GIT_MIRROR_PATH`
  pointing at (a) a bare mirror and (b) a non-bare checkout; assert
  `git remote get-url --push origin` never resolves to the RO staged path
  when the source has a real `remote.origin.url`.
- Live: order-349 gate rerun on macOS records an in-forge `git push --dry-run`
  reaching the mirror (or failing with the honest diagnosis), never
  `remote unpack failed`/RO-filesystem errors against src-host.
