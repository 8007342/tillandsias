#!/usr/bin/env bash
# Simplified Chinese locale strings for Tillandsias Forge
# Stub — inherits English defaults.
# @trace spec:forge-welcome

# Source English as base
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_dir/en.sh"

# Override with Simplified Chinese translations as they become available

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 代理入职"
L_AGENT_ONBOARDING_HINT="阅读第一圈指南，cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md"
