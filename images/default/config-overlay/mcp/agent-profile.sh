#!/usr/bin/env bash
# @trace gap:ON-008
# agent-profile.sh — Auto-load user's preferred agent profile from config.
#
# This script exports agent-specific environment variables based on the
# TILLANDSIAS_AGENT value (e.g., "claude", "opencode", "opencode-web").
#
# Usage: source agent-profile.sh
#
# Environment variables set:
#   - AGENT_PROFILE: Name of the active agent profile
#   - AGENT_PREFERENCE: User's selected agent from config
#   - AGENT_SUPPORTS_WEB: "yes" if agent supports web/browser mode
#
# These variables are useful for shell scripts and tools that need to
# adapt behavior based on which coding agent is running.

set -euo pipefail

# Determine agent profile from TILLANDSIAS_AGENT env var
# (set by Tillandsias launcher from config -> container profile)
AGENT_PREFERENCE="${TILLANDSIAS_AGENT:-opencode-web}"

# Export agent preference for downstream tools
export AGENT_PREFERENCE

# Set profile-specific configuration
case "${AGENT_PREFERENCE}" in
    opencode-web)
        # OpenCode Web: browser-based UI, headless HTTP server
        export AGENT_PROFILE="opencode-web"
        export AGENT_SUPPORTS_WEB="yes"
        export AGENT_DISPLAY_NAME="OpenCode Web"
        ;;
    opencode)
        # OpenCode: CLI-first agent with terminal UI
        export AGENT_PROFILE="opencode"
        export AGENT_SUPPORTS_WEB="no"
        export AGENT_DISPLAY_NAME="OpenCode"
        ;;
    claude)
        # Claude: CodeAgent integration for interactive coding
        export AGENT_PROFILE="claude"
        export AGENT_SUPPORTS_WEB="no"
        export AGENT_DISPLAY_NAME="Claude"
        ;;
    *)
        # Unknown agent — fallback to safe default
        export AGENT_PROFILE="unknown"
        export AGENT_SUPPORTS_WEB="no"
        export AGENT_DISPLAY_NAME="Unknown"
        ;;
esac

# Export all agent-related variables so they're available to shell and tools
export AGENT_PROFILE AGENT_SUPPORTS_WEB AGENT_DISPLAY_NAME

# Log agent profile activation (optional, useful for debugging)
if [ "${TRACE_LIFECYCLE:-0}" = "1" ]; then
    echo "[agent-profile] loaded: AGENT_PREFERENCE=${AGENT_PREFERENCE} AGENT_PROFILE=${AGENT_PROFILE}" >&2
fi
