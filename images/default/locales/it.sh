#!/usr/bin/env bash
# Italian locale strings for Tillandsias Forge
# Stub — inherits English defaults.
# @trace spec:forge-welcome

# Source English as base
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_dir/en.sh"

# Override with Italian translations as they become available

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 Onboarding agente"
L_AGENT_ONBOARDING_HINT="cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md per la guida first-turn"
