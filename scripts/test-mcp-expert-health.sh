#!/usr/bin/env bash
# @trace order:737-zcj5, spec:meta-orchestration
set -uo pipefail

# Fixture for the MCP expert health probe (order 737-zcj5).
#
# Reproduces the shapes the probe exists to tell apart: both experts answering,
# both down, a partial outage that must name only the failing server, and an
# environment where no expected expert is registered at all. Also pins the
# verdict grammar to exactly one line, and proves the health JSONL carries the
# durable trace — the verdict line is ephemeral stdout, the log is what a later
# cycle can find.
#
# The args-honoured scenario is the regression guard for this script's own first
# draft, which read `.command` and dropped `.args`, launched a bare `bash`, and
# reported two healthy experts as down. A false outage is as damaging as a
# missed one: it trains agents to ignore the signal.
#
# Every scenario registers a stand-in server whose behaviour is fully determined
# by the fixture's registration JSON, so nothing here touches a real MCP server,
# a real ledger, or the network. Exit 0 only when all scenarios match.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/check-mcp-expert-health.sh" fixture
