## Why

Users land in a bare bash prompt with no context about what they're looking at. They don't know what's mounted, what tools are available, or even what shell they're in. The terminal should feel welcoming, informative, and opinionated — like Kitty on Hyprland, but showing the host-to-guest mapping that makes Tillandsias unique.

## What Changes

- **Default shell: fish** — Terminal and --bash modes now launch `fish` instead of `bash`. Fish has autosuggestions, syntax highlighting, and tab completion out of the box.
- **Welcome message script** — `forge-welcome.sh` displays on every terminal launch: project name, forge/host OS versions, mount points with color-coded access (red=ro, green=rw, blue=encrypted), and a rotating tip.
- **Additional terminal tools** — Add `zoxide` (aliased as `z`), and ensure modern file utils are present (eza, bat, fd already added in forge-shell-tools).
- **Rust handler changes** — `handle_terminal` and `--bash` mode launch `fish` with the welcome script sourced, instead of bare `bash`.

## Capabilities

### New Capabilities
- `forge-welcome`: Welcome message script with OS info, mount mapping, and rotating tips

### Modified Capabilities
- `tray-app`: Terminal menu item launches fish with welcome message
- `cli-bash-mode`: `--bash` flag now launches fish (rename is cosmetic — flag stays `--bash` for familiarity)

## Impact

- **New files**: `images/default/forge-welcome.sh` (welcome message script)
- **Modified files**: `src-tauri/src/handlers.rs` (fish entrypoint), `src-tauri/src/runner.rs` (fish entrypoint), `flake.nix` (if any missing tools), `images/default/shell/config.fish` (source welcome on interactive start)
