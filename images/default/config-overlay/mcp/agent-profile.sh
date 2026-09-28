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
# Live launchers always set TILLANDSIAS_AGENT. Keep the compatibility fallback
# aligned with deprecated entrypoint.sh for cached images instead of silently
# identifying every unset harness as OpenCode Web.
AGENT_PREFERENCE="${TILLANDSIAS_AGENT:-claude}"

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
    codex)
        # Codex: OpenAI's CLI coding agent
        export AGENT_PROFILE="codex"
        export AGENT_SUPPORTS_WEB="no"
        export AGENT_DISPLAY_NAME="Codex"
        ;;
    antigravity)
        # Google Antigravity: Gemini-powered coding agent
        export AGENT_PROFILE="antigravity"
        export AGENT_SUPPORTS_WEB="no"
        export AGENT_DISPLAY_NAME="Antigravity"
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

# ORDER 1446-qkx4 — skills every project in a forge gets, not only Tillandsias
# checkouts. The image copies the repo's skills/ to /opt/skills, but nothing
# linked them anywhere a harness looks, so a forge on any other project saw
# none of them. Link each GENERIC skill into every harness's USER-level skill
# directory. Never overwrite an entry that is already there (a project or the
# user may own that name), never fail: this file is sourced under set -e.
TILLANDSIAS_FORGE_GENERIC_SKILLS="${TILLANDSIAS_FORGE_GENERIC_SKILLS:-project-discipline}"
link_forge_generic_skills() {
    local src_root="${TILLANDSIAS_SHARED_SKILLS_ROOT:-/opt/skills}" home="${HOME:-/home/forge}" skill dir
    for skill in $TILLANDSIAS_FORGE_GENERIC_SKILLS; do
        [ -f "$src_root/$skill/SKILL.md" ] || continue
        for dir in "$home/.claude/skills" "$home/.codex/skills" "$home/.gemini/skills" "$home/.config/opencode/skill"; do
            [ -e "$dir/$skill" ] || [ -L "$dir/$skill" ] && continue
            mkdir -p "$dir" 2>/dev/null && ln -s "$src_root/$skill" "$dir/$skill" 2>/dev/null
        done
    done
    return 0
}
link_forge_generic_skills || true

# Log agent profile activation (optional, useful for debugging)
if [ "${TRACE_LIFECYCLE:-0}" = "1" ]; then
    echo "[agent-profile] loaded: AGENT_PREFERENCE=${AGENT_PREFERENCE} AGENT_PROFILE=${AGENT_PROFILE}" >&2
fi
