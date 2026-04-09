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
L_RETRY_HINT="To retry: restart the container"
L_CLEAR_CACHE_CLAUDE="To clear cache: rm -rf ~/.cache/tillandsias/claude/"
L_CLEAR_CACHE_OPENCODE="To clear cache: rm -rf ~/.cache/tillandsias/opencode/"
L_OPENCODE_INSTALL_FAILED="ERROR: OpenCode failed to install."
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="project:"
L_BANNER_AGENT="agent:"
L_BANNER_MODE_MAINTENANCE="mode:    maintenance"
L_AGENT_NOT_AVAILABLE="Claude Code not available. Starting bash."
L_OPENCODE_NOT_AVAILABLE="OpenCode not available. Starting bash."
L_UNKNOWN_AGENT="Unknown agent '%s'. Starting bash."

# ── CA / proxy warnings ─────────────────────────────────────────
L_WARN_CA_INSTALL="WARNING: Failed to install CA certificate — proxy HTTPS caching may not work"
L_WARN_CA_UPDATE="WARNING: Failed to update CA trust store"

# ── Git mirror messages ─────────────────────────────────────────
L_WARN_PUSH_URL="WARNING: Failed to set push URL — git push may not work"
L_GIT_CLONE_FAILED="ERROR: Could not clone project from git service."
L_GIT_CLONE_HINT="The git service may not be running. Dropping to shell."
L_GIT_EPHEMERAL="All changes must be committed to persist. Uncommitted work is lost on stop."

# ── Auth / init warnings ────────────────────────────────────────
L_WARN_GH_AUTH="WARNING: gh auth setup-git failed — git push may not authenticate"
L_WARN_OPENSPEC_INIT="WARNING: OpenSpec init failed — /opsx commands may not work"

# ── Installer exit warnings ──────────────────────────────────────
L_WARN_OPENCODE_EXIT="WARNING: OpenCode installer exited with code"
L_WARN_OPENCODE_UPDATE_EXIT="WARNING: OpenCode update exited with code"

# ── Updating messages ───────────────────────────────────────────
L_UPDATING_CLAUDE="Updating Claude Code..."
L_UPDATING_OPENCODE="Updating OpenCode..."

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Project"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Mounts"
L_WELCOME_PROJECT_AT="→ Project at /home/forge/src/%s"
L_WELCOME_SECURITY="Security"
L_WELCOME_NETWORK="Network"
L_WELCOME_NETWORK_DESC="enclave only (no internet, packages via proxy)"
L_WELCOME_CREDENTIALS="Credentials"
L_WELCOME_CREDENTIALS_DESC="none (git auth via mirror service)"
L_WELCOME_CODE="Code"
L_WELCOME_CODE_DESC="cloned from git mirror (uncommitted work is ephemeral)"
L_WELCOME_SERVICES="Services"
L_WELCOME_PROXY_DESC="caching HTTP/S proxy (allowlisted domains)"
L_WELCOME_GIT_DESC="git mirror + auto-push to remote"
L_WELCOME_INFERENCE_DESC="ollama (local LLM)"

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
