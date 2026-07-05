# Coordination: freeze sibling drift and integrate secure-wire + embedded-guest branches — 2026-07-05

- class: coordination+integration
- owner: any coordinator, with macOS and Windows evidence from their hosts
- status: ready
- order: 191
- trace: methodology/multi-host-development.yaml, methodology/convergence.yaml,
  plan/issues/secure-channel-maturity-ladder-2026-07-04.md,
  plan/issues/embedded-guest-binary-linux-build-2026-07-05.md

## Finding

`origin/osx-next` is 12 commits ahead of `origin/linux-next` and
`origin/windows-next` is 6 commits ahead. Both exceed the distributed-work drift
threshold Dmax=5 while the active product path spans all three branches:

- secure host<->guest control wire behind `TILLANDSIAS_SECURE_CONTROL_WIRE`;
- embedded source-matching Linux guest binary selection and injection;
- Fedora 44 VM initialization and Podman control-plane bring-up;
- top-host terminal launch of forge harnesses in the deepest forge container.

New platform feature work should pause until each sibling branch first merges
`origin/linux-next` and records either smoke evidence or exact conflicts.

## Non-negotiables

- Cross-branch integration is merge-only. Do not cherry-pick or rebase published
  `osx-next` / `windows-next` commits into `linux-next`.
- Shared `plan/`, `methodology/`, `openspec/`, and cheatsheet edits land directly
  on `linux-next`.
- macOS tray / VZ implementation code remains on `osx-next`; Windows tray / WSL
  implementation code remains on `windows-next` until the integration merge.
- No host credential/config material may enter a forge container while validating
  the top-host terminal launch path.

## Required evidence

macOS:
- merge `origin/linux-next` into `osx-next`;
- rebuild the tray with current embedded Linux guest assets;
- boot a cold Fedora 44 VZ guest;
- prove flag OFF still runs the plaintext path;
- prove flag ON reaches GitHub login, remote-project listing, and forge launch
  over the secure host<->guest wire, or file the exact failing boundary.

Windows:
- merge `origin/linux-next` into `windows-next`;
- preserve the hvsocket secure-wrapper and embedded-binary work already on the
  sibling branch;
- run WSL2 flag-OFF and flag-ON smoke evidence, or file the exact failing boundary.

Linux/coordinator:
- do not integrate sibling code from a dirty worktree;
- merge sibling branches in a clean worktree and run the focused verification gate;
- if conflicts hit shared ledgers, keep `linux-next` as the authoritative
  coordination source and preserve sibling notes as semantic upserts.

## Exit criteria

- Branch drift is back under Dmax or has a named conflict packet.
- M1 secure-channel evidence is recorded per platform, or the missing hop is
  explicitly assigned.
- Embedded guest binary work is aligned around order 190 as the Linux artifact
  contract consumed by macOS and Windows.

## macOS run result 2026-07-05T18:53Z

MacOS meta-orchestration did not merge or implement because the local `osx-next`
worktree has uncommitted tracked and untracked implementation/package changes.
This is a local macOS blocker, not a Linux blocker. Linux should continue with
order 190 while macOS checkpoints/cleans WIP before attempting the merge.

## macOS merge result 2026-07-05T22:25Z

- `origin/linux-next` merged into `osx-next` (34 commit catch-up, no feature loss)
- 3 conflicts resolved (vsock_server.rs, 2 plan files — linux-next authoritative)
- `cargo fmt --all --check`, `cargo check -p tillandsias-macos-tray`, all 53+12 tests green
- Pushed to `origin/osx-next` at `39e9df27`
- Branch drift from linux-next resolved. Order 193 (macos-vz-home-src-mount) unblocked.
