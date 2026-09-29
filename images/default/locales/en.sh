#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja
# Tillandsias Forge — English locale bundle
# Sourced by lib-common.sh and forge-welcome.sh after locale detection (no
# entrypoint*.sh references an L_ key; 792-7bt5 removed 34 keys nothing read).
# Variables prefixed with L_ to avoid collisions with other env vars.

# ── entrypoint.sh ────────────────────────────────────────────
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="project:"
L_BANNER_AGENT="agent:"

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="Project"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="Mounts"
L_WELCOME_SECURITY="Security"
L_WELCOME_NETWORK="Network"
L_WELCOME_NETWORK_DESC="enclave only (no internet, packages via proxy)"
L_WELCOME_CREDENTIALS="Credentials"
L_WELCOME_CREDENTIALS_DESC="none (git auth via mirror service)"
L_WELCOME_CODE="Code"
L_WELCOME_CODE_DESC="cloned from git mirror (uncommitted work is ephemeral)"
L_WELCOME_SERVICES="Services"
L_WELCOME_PROXY_DESC="caching HTTP/S proxy (allowlisted domains)"
L_WELCOME_GIT_DESC="git mirror (git push origin routes through tillandsias-git:9418)"
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

# ── Cheatsheets ────────────────────────────────────────────
# Note: The cheatsheet pointer is currently hardcoded in forge-welcome.sh
# and does not use locale variables. This is kept for future localization
# if we make the banner fully locale-aware.
L_AGENT_ONBOARDING="🤖 Agent onboarding"
L_AGENT_ONBOARDING_HINT="cat \$TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md for first-turn guide"

# ── Error messages (lib-localized-errors.sh) ────────────────
L_ERROR_CONTAINER_FAILED="ERROR: Container failed to start"
L_ERROR_CONTAINER_HINT="Try restarting the container or checking logs for details."

L_ERROR_IMAGE_MISSING="ERROR: Container image not found"
L_ERROR_IMAGE_HINT="Rebuild the image or check that it exists. Verify disk space for large images."

L_ERROR_NETWORK="ERROR: Network error"
L_ERROR_NETWORK_HINT="Check proxy settings (HTTPS_PROXY env) and that network services are running."

L_ERROR_GIT_CLONE="ERROR: Git clone failed"
L_ERROR_GIT_HINT="Verify credentials, SSH keys, or restart the git service. Check git config."

L_ERROR_AUTH="ERROR: Authentication failed"
L_ERROR_AUTH_HINT="Re-setup credentials with 'gh auth login' or check git config."
