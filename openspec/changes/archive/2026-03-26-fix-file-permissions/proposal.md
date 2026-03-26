## Why

Files created inside Tillandsias forge containers (via `--userns=keep-id`) can end up with
restrictive permissions on the host bind mount. Specifically, files created by container
processes under `~/src/<project>/` — such as `.bash-private`, `.opencode/`, `openspec/`,
`.claude/` — may have no write permission for the host user, requiring `chmod` or `sudo rm`
to modify or delete them via a file browser.

Two root causes combine to produce this problem:

1. **Nix store files are read-only (0444).** When `fakeRootCommands` in `flake.nix` copies
   files from the Nix store into the image (e.g., shell configs to `/etc/skel/`), those files
   land as 0444. The subsequent `chown -R 1000:1000 ./home/forge` fixes ownership but does
   not fix mode. When `entrypoint.sh` deploys these files into `$HOME`, they arrive as
   non-writable, which can confuse tools that attempt to update them.

2. **No umask is set in the entrypoint.** Container processes inherit whatever umask the
   container runtime sets (commonly 0022, but sometimes 0077 on hardened systems, or tools
   like `npm install` and `openspec init` create artefacts with 0444/0555). Without an
   explicit `umask 0022` in `entrypoint.sh`, every spawned process (OpenCode, OpenSpec, fish,
   bash, npm) can create files the host user cannot write.

## What Changes

- **`flake.nix` — customization layer**: After `chown -R 1000:1000 ./home/forge`, add
  `chmod -R u+rw ./home/forge` so all copied files are at minimum user-readable and
  user-writable, regardless of the Nix store mode they arrived with. Also add
  `chmod -R a+r ./etc/skel` to ensure skel files are readable when deployed.

- **`images/default/entrypoint.sh` — umask**: Add `umask 0022` immediately after
  `set -euo pipefail`. This ensures all files created by this script and any process it
  execs (OpenCode, npm, openspec, bash) inherit a permissive umask, so new files are
  user-writable and group/world-readable by default.

- **`images/default/shell/bashrc` — umask**: Add `umask 0022` so interactive bash sessions
  inside the container also enforce the same policy.

- **`images/default/shell/zshrc` — umask**: Add `umask 0022` for interactive zsh sessions.

- **`images/default/shell/config.fish` — umask**: Add `umask 022` (fish syntax) for
  interactive fish sessions.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `fix-file-permissions`: Container-created files on host bind mounts are always
  user-writable. No `chmod` or `sudo rm` required after container exit.

## Impact

- **Modified files**: `flake.nix`, `images/default/entrypoint.sh`,
  `images/default/shell/bashrc`, `images/default/shell/zshrc`,
  `images/default/shell/config.fish`
- **No Rust changes required**: The `--userns=keep-id` mapping already ensures container
  UID matches host UID; the fix is at the file-creation layer, not the orchestration layer.
- **Image rebuild required**: `flake.nix` and shell config changes require rebuilding the
  forge image.
