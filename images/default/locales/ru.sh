#!/usr/bin/env bash
# Russian locale strings for Tillandsias Forge
# Stub — inherits English defaults.
# @trace spec:forge-welcome

# Source English as base
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_dir/en.sh"

# Override with Russian translations as they become available

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 Ознакомление агента"
L_AGENT_ONBOARDING_HINT="cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md для первого направления"
