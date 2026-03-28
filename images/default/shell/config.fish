# Tillandsias Forge — Fish shell configuration
# Auto-sourced from /etc/fish/conf.d/ inside the container image.

# ── Permissions ───────────────────────────────────────────────
# Ensure files created in interactive sessions (and by tools we invoke)
# are user-writable on the host bind mount.
umask 022

# ── PATH — Claude Code and OpenSpec cached in ~/.cache/tillandsias/
fish_add_path -gP $HOME/.cache/tillandsias/claude/bin
fish_add_path -gP $HOME/.cache/tillandsias/openspec/bin
fish_add_path -gP $HOME/.local/bin

# Suppress fish's default "Welcome to fish" greeting
set -g fish_greeting ""

# Welcome message on interactive login
if status is-interactive
    and not set -q TILLANDSIAS_WELCOME_SHOWN
    set -gx TILLANDSIAS_WELCOME_SHOWN 1
    if test -f /usr/local/share/tillandsias/forge-welcome.sh
        bash /usr/local/share/tillandsias/forge-welcome.sh
    end
end
