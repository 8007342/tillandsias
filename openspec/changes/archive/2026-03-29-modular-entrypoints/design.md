## Context

The current architecture uses a single `images/default/entrypoint.sh` that receives a `TILLANDSIAS_AGENT` environment variable and branches on its value to decide what to install and launch. The Rust code in `handlers.rs` sets this env var and, for maintenance terminals, overrides the entrypoint entirely with `--entrypoint fish`. This creates a fractured execution model:

- **Forge containers**: Use the default image entrypoint, which reads `TILLANDSIAS_AGENT` and installs either OpenCode or Claude, then launches the selected agent.
- **Maintenance terminals**: Bypass the entrypoint entirely with `--entrypoint fish`, losing all setup (gh auth, shell config deployment, PATH setup). The welcome message only works because fish's `config.fish` calls `forge-welcome.sh` independently.
- **Web containers**: Use a completely separate image (`tillandsias-web`) with its own entrypoint. Already correctly isolated.

The image is built via `flake.nix` which copies the entrypoint to `/usr/local/bin/tillandsias-entrypoint.sh` and sets it as the Entrypoint in the OCI config. All other scripts are already in the image (shell configs in `/etc/skel/`, welcome script in `/usr/local/share/tillandsias/`).

**Constraints:**
- All entrypoints must work inside the existing Nix-built image
- The image config can only have ONE default Entrypoint — the Rust code must use `--entrypoint` to override for non-default types
- Shared setup (umask, trap, gh auth, shell configs) must not be duplicated
- Each entrypoint must be independently testable (run it in isolation, it works)
- No additional image layers or size increase

## Goals / Non-Goals

**Goals:**
- Each container type has its own focused entrypoint script
- Shared setup is factored into a sourceable library (`entrypoint-common.sh`)
- Each entrypoint only installs/configures what it needs
- Each entrypoint only receives the secrets it needs (enforced by the Rust launch code, not the script)
- Maintenance terminals get proper setup (gh auth, PATH, welcome) instead of bypassing everything
- Clear lifecycle: install -> update -> configure -> banner -> launch
- Clear error handling: failures at each step produce distinct, actionable messages

**Non-Goals:**
- Change the image build system (still Nix, still flake.nix)
- Change the container image base (still Nix-based)
- Add new tools or packages to the image
- Change the web image (already correctly isolated)
- Implement the config-driven launch in Rust (separate change: `config-driven-launch`)

## Decisions

### D1: Shared setup library — `entrypoint-common.sh`

**Choice:** Create `images/default/entrypoint-common.sh` containing:
```bash
set -euo pipefail
umask 0022
trap 'exit 0' SIGTERM SIGINT

# Ensure secrets directories exist
mkdir -p ~/.config/gh 2>/dev/null || true
touch ~/.gitconfig 2>/dev/null || true

# Bridge gh auth -> git push
command -v gh &>/dev/null && gh auth setup-git 2>/dev/null || true

# Deploy shell configs if not present
for f in .bashrc .zshrc; do
    [ -f "$HOME/$f" ] || cp "/etc/skel/$f" "$HOME/$f" 2>/dev/null || true
done
mkdir -p "$HOME/.config/fish"
[ -f "$HOME/.config/fish/config.fish" ] || \
    cp "/etc/skel/.config/fish/config.fish" "$HOME/.config/fish/config.fish" 2>/dev/null || true

# Common PATH setup
CACHE="$HOME/.cache/tillandsias"
export PATH="$CACHE/openspec/bin:$HOME/.local/bin:$PATH"
```

Each entrypoint sources this with `source /usr/local/lib/tillandsias/entrypoint-common.sh`.

**Why:** The 6 shared setup steps (umask, trap, gh auth, shell configs, mkdir, PATH) are genuinely shared across all container types. Duplicating them in each entrypoint creates maintenance burden. A sourceable library eliminates duplication while keeping each entrypoint independently readable.

**Location:** `/usr/local/lib/tillandsias/` — standard location for shared shell libraries in FHS.

### D2: Per-type entrypoints

| Script | Purpose | Installs | Secrets needed |
|--------|---------|----------|----------------|
| `entrypoint-forge-opencode.sh` | Launch OpenCode | OpenCode binary, OpenSpec | gh, git |
| `entrypoint-forge-claude.sh` | Launch Claude Code | Claude Code (npm), OpenSpec | gh, git, claude dir, API key |
| `entrypoint-terminal.sh` | Interactive shell | Nothing (tools already in image) | gh, git |
| `entrypoint-web.sh` | Already exists | Nothing | None |

Each script follows a fixed lifecycle:

```
1. source entrypoint-common.sh           # Shared setup
2. Install/update agent runtime           # Agent-specific
3. Find project directory                 # cd to /home/forge/src/*
4. Initialize OpenSpec if needed          # First-launch only
5. Print banner                           # Agent-specific welcome
6. exec <agent>                           # Launch runtime
```

Steps 2-5 vary by type. Step 1 and 6 are always present.

### D3: Image default entrypoint = Claude forge

**Choice:** The image's OCI `Entrypoint` config in `flake.nix` defaults to `entrypoint-forge-claude.sh` (current default agent). The Rust code sets `--entrypoint` for all other types.

**Why:** Claude is the default agent (`SelectedAgent::default() = Claude`). Users who launch via `podman run` without Tillandsias get the default experience. The Rust code always explicitly sets the entrypoint for non-default types, so the default only matters for manual podman usage.

### D4: Terminal entrypoint replaces `--entrypoint fish` hack

**Choice:** Instead of `--entrypoint fish` (which bypasses all setup), use `--entrypoint /usr/local/bin/entrypoint-terminal.sh`.

**Why:** The current `--entrypoint fish` hack skips gh auth, shell config deployment, and PATH setup. The terminal entrypoint runs the shared setup, shows the welcome banner, then execs fish. Users get a properly configured environment.

### D5: Transition strategy — keep old entrypoint temporarily

**Choice:** Keep the existing `entrypoint.sh` as a thin redirect that sources common and dispatches to the correct per-type script based on `TILLANDSIAS_AGENT`. This ensures containers built with old image versions still work.

**Why:** Users may have cached images from before the update. The old entrypoint must not break. After one version cycle (all users have updated), the old entrypoint can be removed.

```bash
#!/usr/bin/env bash
# DEPRECATED — kept for backward compatibility with cached images.
# New launches use per-type entrypoints directly via --entrypoint.
source /usr/local/lib/tillandsias/entrypoint-common.sh
case "${TILLANDSIAS_AGENT:-claude}" in
    opencode) exec /usr/local/bin/entrypoint-forge-opencode.sh "$@" ;;
    claude)   exec /usr/local/bin/entrypoint-forge-claude.sh "$@" ;;
    *)        exec /usr/local/bin/entrypoint-terminal.sh "$@" ;;
esac
```

### D6: OpenSpec installation in forge entrypoints only

**Choice:** OpenSpec install/init is only in the two forge entrypoints (opencode, claude). The terminal entrypoint does not install or initialize OpenSpec.

**Why:** OpenSpec is a development workflow tool used alongside AI agents. Maintenance terminals are for debugging — they should not modify the project (no `openspec init`). If a user wants OpenSpec in a terminal, they can run `openspec init` manually.

## Architecture

```
/usr/local/lib/tillandsias/
  entrypoint-common.sh          # Shared setup (sourced, not executed)

/usr/local/bin/
  tillandsias-entrypoint.sh     # DEPRECATED redirect (backward compat)
  entrypoint-forge-opencode.sh  # OpenCode forge
  entrypoint-forge-claude.sh    # Claude forge
  entrypoint-terminal.sh        # Maintenance terminal (fish)

/usr/local/share/tillandsias/
  forge-welcome.sh              # Welcome banner (unchanged)
```

## Risks / Trade-offs

**[Extra scripts in image]** Four entrypoints + one library instead of one script. Mitigation: Total size is ~5KB — negligible vs. the 800MB+ image. Each script is shorter and simpler than the original.

**[Backward compatibility window]** The deprecated redirect must be maintained for one version cycle. Mitigation: The redirect is 8 lines and trivial to maintain. Remove it in the next major version.

**[Rust code must select entrypoint]** The Rust code now needs to know which entrypoint to use for each container type. Mitigation: This is handled by the `config-driven-launch` change. In the interim, a simple match on `SelectedAgent` + container type suffices.
