## Why

The forge container's bash mode drops users into a bare-bones shell with only the essentials. Power users troubleshooting inside the container need a healthy set of terminal tools — alternative shells, file managers, editors, and modern CLI sugar. AJ doesn't need to know these exist, but developers who use `--bash` or the Terminal menu should feel at home.

## What Changes

- **Additional shells**: Install `fish` and `zsh` alongside bash, preconfigured and ready to start
- **File management**: `mc` (Midnight Commander) for visual file browsing
- **Editors**: `vim`, `nano` (pico-compatible)
- **Modern CLI tools**: `eza` (modern ls), `bat` (cat with syntax highlighting), `fd` (modern find), `fzf` (fuzzy finder), `zoxide` (smart cd), `htop` (process viewer), `tree` (directory tree)
- **Bash enhancements**: sensible prompt, aliases (`ll`, `la`, `..`), colored output by default
- **Shell config**: Basic `.bashrc`, `.config/fish/config.fish`, and `.zshrc` with sane defaults

## Capabilities

### New Capabilities
- `forge-shell-tools`: Terminal tools, alternative shells, and shell configuration in the forge image

### Modified Capabilities
(none — changes are to the Nix flake image definition, not Rust code)

## Impact

- **Modified files**: `flake.nix` (add packages to forge-image), `images/default/entrypoint.sh` (deploy shell configs)
- **New files**: `images/default/shell/bashrc`, `images/default/shell/config.fish`, `images/default/shell/zshrc`
- **Image size increase**: Estimated +50-100MB compressed (shells + tools)
- **No Rust code changes**
