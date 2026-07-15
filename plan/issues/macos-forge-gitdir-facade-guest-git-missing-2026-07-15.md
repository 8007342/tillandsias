# P1: macOS forge lane DOA on the merged gitdir facade — guest VM has no `git`, and the fail-closed mask was a tmpcopyup copy-bomb

- Date: 2026-07-15
- Class: bugfix (release-blocking on the macOS lane; order 341/342 family)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-15T05:21Z
- Discovered by: orders 332/349 live gates (cold + warm `--opencode`, tray git 5497e10a)
- Related: forge-shared-checkout-destructive-clean-2026-07-13.md (order 342 reduction), write_forge_repo_gitdir / write_forge_index / append_forge_repo_gitdir_mount_args (headless main.rs)
- Pickup: linux (facade owner), with the mask half FIXED on osx-next this cycle

## Failure chain (deterministic, reproduced twice)

1. `write_forge_repo_gitdir` shells out to `git` (`git_config_set`,
   `write_forge_index` → `git rev-parse` / `git read-tree`). The Fedora
   Cloud GUEST OS ships no git binary (`command -v git` empty in the VM;
   git lives in the containers) → the facade build fails at its first
   shell-out, leaving a partial facade dir (config/HEAD/refs, no index).
2. The fail-closed fallback masked the host `.git` with
   `--tmpfs …/.git:size=8m,mode=0700`. Podman defaults tmpfs mounts to
   `tmpcopyup`, which COPIES the underlying content into the fresh tmpfs —
   on macOS the underlying is the operator's real checkout `.git` over
   virtiofs (hundreds of MB) → `crun: write: No space left on device` at
   container start, forge attach 126, lane dead. No kernel/journal trace
   (tmpfs-cap ENOSPC is silent) — the guest showed 241G free while
   launches died, a genuinely misleading failure surface.
3. Linux never sees either half: its guests get mirror-materialized
   checkouts (no fat host `.git` under the mask) and its facade... also
   presumably runs where git exists. macOS live gates (order 349's whole
   purpose) caught both.

## Fixed this cycle (osx-next)

- Both mask sites now mount `size=8m,mode=0700,notmpcopyup` — a fail-closed
  mask is EMPTY by definition; pin updated
  (`facade errors must mask host .git with a fail-closed EMPTY tmpfs`).
  The lane launches again; in-forge repo git operations fail closed (as
  designed for facade-unavailable).

## Remaining for the facade owner (linux)

1. Drop the guest-`git` dependency: `git_config_set` writes trivial INI —
   replace with direct writes; `write_forge_index` needs a real decision
   (ship git in the guest recipe? build the index in-container at
   entrypoint where git exists? pure-Rust index write?). Until then the
   facade NEVER materializes on macOS guests and every macOS forge session
   runs fail-closed (no repo git).
2. Add "guest OS binary dependencies of headless" to the conformance/
   litmus surface — a shared-crate feature that shells out must declare
   and probe its guest-side dependencies, or fail with a diagnosis instead
   of silently degrading to a fallback that (until today) crashed.

## Repro

Any `--opencode` on a macOS VZ guest with the merged facade code and a
real host checkout: pre-fix crashes ENOSPC; post-fix launches with a
masked `.git`.

## Additional evidence (same cycle, order-349 gate run)

`read_host_project_origin_url` is a third guest-`git` shell-out casualty:
with no origin URL readable, `write_forge_gitconfig` omits the
`[url "git://tillandsias-git/…"] insteadOf` section entirely — the live
order-349 gate shows `/home/forge/.gitconfig` mounted and honored
(safe.directory, empty credential.helper, hooksPath all present via
`git config --global --show-origin --list`) but NO mirror rewrite. So the
single missing guest binary silently disables: the mirror redirect, the
repo gitdir facade, and (pre-notmpcopyup) the whole lane. TLS parity is
healthy on the same run (curl/node/python all 200 through the proxy with
no per-client CA override variables; NODE_USE_SYSTEM_CA=1 is the
system-trust design). Order 349 is blocked on exactly this packet.
