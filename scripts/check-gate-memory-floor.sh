#!/usr/bin/env bash
# @trace order:1176-fn2p
# @trace order:2167-gmfl
#
# BOOTSTRAP for scripts/lua/check-gate-memory-floor.lua, which is the decider:
# refuse a gate BY NAME on a host with too little memory to start it (1176-fn2p).
# Every rule, verdict and exit code lives there; this file only finds a runner.
#
# WHY THIS STAYS SHELL. build.sh asks it at gate START, before anything is
# compiled, so on a fresh checkout there is no plan binary to run Lua with. The
# gate must still get a verdict it can score, and the readers know exactly one
# word for "nothing was asserted" (1354-apns), so the no-binary case prints a
# named could-not-run AND a terminal skip:, exit 3 — never "fine", and never a
# refusal that would block a host for lacking a binary the gate is about to build.
#
# The path is the entry point build.sh and the consumer fixtures name, so it is
# kept; the judged logic is not here. History: git log -p -- this file.
set -uo pipefail
_gmf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 3

# shellcheck source=/dev/null
. "$_gmf_root/scripts/plan-binary-probe.sh" 2>/dev/null || true
# Resolve from the CHECKOUT and absolutise (84f37ff24, class 1401-x76w):
# resolve_plan_binary falls back to a cwd-relative ./target/release, so a caller
# in another cwd (the host-memory fixture's driver) found none unless it handed
# down its own TILLANDSIAS_PLAN_BIN. An explicit one keeps its caller-relative
# meaning.
_gmf_resolve_plan() {
    local _p
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
        resolve_plan_binary 2>/dev/null
        return
    fi
    _p="$(cd "$_gmf_root" && resolve_plan_binary 2>/dev/null)" || return 1
    case "$_p" in
        /*) printf '%s' "$_p" ;;
        *) printf '%s/%s' "$_gmf_root" "${_p#./}" ;;
    esac
}
if command -v resolve_plan_binary >/dev/null 2>&1 \
    && _gmf_plan="$(_gmf_resolve_plan)" && [ -n "$_gmf_plan" ]; then
    TILLANDSIAS_REPO_ROOT="$_gmf_root" exec "$_gmf_plan" script run \
        "$_gmf_root/scripts/lua/check-gate-memory-floor.lua" -- "$@"
fi

# THE REFUSE PATH SURVIVES WITHOUT THE BINARY. A fresh checkout on a low-memory
# host is exactly where the floor matters most, and build.sh only warns on rc 3,
# so a skip here would start that host's first gate unguarded. This fallback
# keeps the one verdict that protects it: MemAvailable plainly below the floor
# refuses, exit 1. Everything subtler (WSL2 guest, bad floor, absent or odd
# meminfo) is the Lua's to judge, and without it nothing else is asserted.
_gmf_floor="${TILLANDSIAS_GATE_MEMORY_FLOOR_MB:-1024}"
_gmf_meminfo=/proc/meminfo
while [ $# -gt 0 ]; do
    case "$1" in
        --meminfo-from) _gmf_meminfo="${2:-}"; shift 2 ;;
        --floor-mb)     _gmf_floor="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
_gmf_kb="$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB.*/\1/p' "$_gmf_meminfo" 2>/dev/null | head -1)"
case "$_gmf_floor" in ''|*[!0-9]*) _gmf_kb="" ;; esac
if [ -n "$_gmf_kb" ] && [ $(( _gmf_kb / 1024 )) -lt "$_gmf_floor" ]; then
    echo "refused:gate:insufficient-memory ($(( _gmf_kb / 1024 ))MB available, floor ${_gmf_floor}MB — read from $_gmf_meminfo; no plan binary yet, judged by the bootstrap)"
    echo "  why: $(( _gmf_kb / 1024 ))MB is available against a ${_gmf_floor}MB floor, so the gate would likely be killed without a verdict" >&2
    echo "  remedy: free memory (stop other gates, VMs or browsers on this host) and re-run; change TILLANDSIAS_GATE_MEMORY_FLOOR_MB only deliberately" >&2
    exit 1
fi

echo "could-not-run:gate-memory:no-plan-binary (no runnable tillandsias-plan yet, so scripts/lua/check-gate-memory-floor.lua cannot run; MemAvailable is not below the floor, and nothing else is asserted about this host's memory)"
echo "skip:gate-memory:no-plan-binary"
exit 3
