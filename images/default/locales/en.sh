#!/usr/bin/env bash
# Tillandsias Forge — English locale bundle
# Sourced by entrypoint.sh and forge-welcome.sh after locale detection.
# Variables prefixed with L_ to avoid collisions with other env vars.

# ── entrypoint.sh ────────────────────────────────────────────
L_INSTALLING_OPENCODE="Installing OpenCode..."
L_INSTALLED_OPENCODE="  OpenCode ready: %s"
L_WARN_OPENCODE="  WARNING: OpenCode binary exists but --version returned nothing."
L_INSTALLING_CLAUDE="Installing Claude Code..."
L_INSTALLED_CLAUDE="  Claude Code ready: %s"
L_WARN_CLAUDE="  WARNING: Claude Code binary exists but --version returned nothing."
L_CLAUDE_NOT_FOUND="  Claude Code binary not found after install."
L_INSTALL_FAILED_CLAUDE="  ERROR: npm install failed. See output above for details."
L_INSTALLING_OPENSPEC="Installing OpenSpec..."
L_INSTALLED_OPENSPEC="  ✓ OpenSpec installed"
L_OPENSPEC_NOT_FOUND="  ✗ OpenSpec binary not found after install"
L_OPENSPEC_FAILED="  OpenSpec install failed (non-fatal, continuing)"
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="project:"
L_BANNER_AGENT="agent:"
L_BANNER_MODE_MAINTENANCE="mode:    maintenance"
L_AGENT_NOT_AVAILABLE="Claude Code not available. Starting bash."
L_OPENCODE_NOT_AVAILABLE="OpenCode not available. Starting bash."
L_UNKNOWN_AGENT="Unknown agent '%s'. Starting bash."

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Project"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Mounts"
L_WELCOME_PROJECT_AT="→ Project at /home/forge/src/%s"

# ── Tips (rotating, shown at login) ──────────────────────────
L_TIP_1="Type help to learn about the Fish shell"
L_TIP_2="Try Midnight Commander with mc"
L_TIP_3="Browse files with eza --tree"
L_TIP_4="Use Tab for autocomplete suggestions"
L_TIP_5="Search history with Ctrl+R"
L_TIP_6="Smart directory jump with z <partial-name>"
L_TIP_7="Preview files with bat <filename>"
L_TIP_8="Find files fast with fd <pattern>"
L_TIP_9="Fuzzy-find anything with fzf"
L_TIP_10="View processes with htop"
L_TIP_11="Show directory tree with tree"
L_TIP_12="Edit files with vim or nano"
L_TIP_13="Fish highlights valid commands in green as you type"
L_TIP_14="Fish suggests from history — press → to accept"
L_TIP_15="Use .. to go up a directory"
L_TIP_16="List files in detail with ll"
L_TIP_17="Switch to bash anytime: type bash"
L_TIP_18="Switch to zsh anytime: type zsh"
L_TIP_19="Check git status with git status"
L_TIP_20="GitHub CLI: gh repo view, gh pr list"
