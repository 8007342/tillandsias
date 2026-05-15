#!/usr/bin/env bash
# Korean locale strings for Tillandsias Forge
# Stub — inherits English defaults.
# @trace spec:forge-welcome

# Source English as base
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_dir/en.sh"

# Override with Korean translations as they become available

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 에이전트 온보딩"
L_AGENT_ONBOARDING_HINT="초기 가이드를 위해 cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md"
