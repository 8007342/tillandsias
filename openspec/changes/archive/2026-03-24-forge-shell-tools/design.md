## Context

The forge image is built via Nix (`flake.nix`) using `dockerTools.buildLayeredImage`. Packages are declared in the `contents` list. The image already includes bash, git, gh, curl, ripgrep, nodejs, and nix. Shell configs don't currently exist — users get a bare bash with no prompt customization.

## Goals / Non-Goals

**Goals:**
- Add fish and zsh as alternative shells (users can just type `fish` or `zsh` to switch)
- Add file manager (mc), editors (vim, nano), and modern CLI tools
- Ship sensible shell configs with a nice prompt, aliases, and colored output
- Keep the image reasonably sized (no kitchen sink)

**Non-Goals:**
- Making fish or zsh the default (bash remains the entrypoint)
- Installing oh-my-zsh or similar frameworks (too heavy, config files are enough)
- Adding GUI tools or X11 dependencies

## Decisions

### Decision 1: Nix packages for all tools

**Choice**: All tools installed as Nix packages in `flake.nix` `contents` list.

**Tool selection**:
| Tool | Purpose | Nix package |
|------|---------|-------------|
| fish | Modern shell with autosuggestions | `fish` |
| zsh | Power-user shell | `zsh` |
| mc | Visual file manager | `mc` |
| vim | Editor (power users) | `vim` |
| nano | Editor (casual users, pico-compatible) | `nano` |
| eza | Modern `ls` replacement | `eza` |
| bat | `cat` with syntax highlighting | `bat` |
| fd | Modern `find` replacement | `fd` |
| fzf | Fuzzy finder | `fzf` |
| zoxide | Smart `cd` (tracks frecency) | `zoxide` |
| htop | Process viewer | `htop` |
| tree | Directory tree display | `tree` |

### Decision 2: Shell configs deployed at image build time

**Choice**: Bake shell configs into the image as static files in `/etc/skel/` and `/home/forge/`. The entrypoint copies them to the user home if not already present (first run).

**Rationale**: Nix images are immutable layers. Shell configs need to be writable at runtime. Deploying from `/etc/skel/` to the home directory at container start preserves user modifications across container recreations (home is mounted).

### Decision 3: Minimal, opinionated configs

**Bash**: Colored prompt with hostname and path, aliases (ll, la, .., grep --color), PATH includes ~/.local/bin.

**Fish**: Default fish prompt (already good), PATH setup, aliases matching bash.

**Zsh**: Simple prompt with git branch, autocompletion enabled, history settings, aliases matching bash.

## Risks / Trade-offs

- **[Image size]** → Adding ~15 packages increases the image. Nix layers efficiently but expect +50-100MB. Acceptable for a dev environment.
- **[zoxide init]** → Needs shell-specific init (eval in bashrc/zshrc, zoxide init fish in config.fish). Handled in the config files.
