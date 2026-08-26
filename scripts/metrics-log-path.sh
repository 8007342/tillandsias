#!/usr/bin/env bash
# metrics-log-path.sh — one answer to "where does a metrics log live", shared by
# every script that writes or reads one.
# @trace order:890-t9pu
#
# WHY THIS IS A SHARED FILE AND NOT THREE COPIES
#
# `/tmp` was the default in four places across three scripts, and `/tmp` IS NOT
# ONE PLACE. On a Windows host `./build.sh` re-execs into WSL2 and writes there,
# while `cycle-metrics.sh` runs in Git Bash and reads a different filesystem.
# MEASURED on yolanda 2026-08-25: 322 `build-check` records on the WSL side, 0
# on the Git Bash side. `timing:` reported `build_check_ms_avg=-` while 322
# measurements sat in a log the reader could not open, and named a `slowest`
# step from a two-day-old file. Every timing metric that host ever published was
# stale or absent — including, until it was found, the measurement of the
# boundary itself.
#
# The defect is a WRITER and a READER disagreeing about a path. Fixing it in one
# script and not the others would have re-created it between the health PROBE
# (`check-mcp-expert-health.sh`, writer) and the health REPORT
# (`cycle-metrics.sh`, reader) — the same bug, one subsystem over. So the path
# rule lives in exactly one file and every participant asks it.
#
# WHERE IT POINTS
#
# The checkout is the one thing both userlands agree on, so the default lives
# under `target/metrics/` — gitignored, already the home for build artifacts,
# and host-local machine state rather than project content. Falls back to `/tmp`
# when there is no writable checkout (a bare invocation, a read-only tree), so a
# forge or an out-of-repo call keeps working exactly as before.
#
# An explicit `TILLANDSIAS_*_LOG` env var always wins — every fixture that names
# its own log keeps working untouched.
#
# ONE-TIME COST, stated rather than hidden: a host with history in `/tmp` starts
# a fresh series here. The rolling views degrade gracefully — they report
# `source=absent` until the first append — so this costs recent averages, not
# correctness. That is the price of the numbers being attributable at all.

# metrics_default_log <basename> [repo_root]
# Prints an absolute path. Never fails; always prints something usable.
metrics_default_log() {
    _mdl_base="${1:?metrics_default_log: basename required}"
    _mdl_root="${2:-}"
    if [ -z "$_mdl_root" ]; then
        _mdl_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd)" || _mdl_root=""
    fi
    if [ -n "$_mdl_root" ] && [ -d "$_mdl_root/.git" ] \
        && mkdir -p "$_mdl_root/target/metrics" 2>/dev/null; then
        printf '%s/target/metrics/%s' "$_mdl_root" "$_mdl_base"
    else
        printf '/tmp/%s' "$_mdl_base"
    fi
}
