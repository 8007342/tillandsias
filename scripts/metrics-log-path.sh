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
# under `.cache/metrics/` — gitignored, host-local machine state rather than
# project content. Falls back to `/tmp` when there is no writable checkout (a
# bare invocation, a read-only tree), so a forge or an out-of-repo call keeps
# working exactly as before.
#
# NOT `target/metrics/`, which this shipped as and which OUR OWN MAINTENANCE
# DESTROYS. `check-build-cache-sweep.sh` fires at 40 GiB or a 14-day marker, and
# both Start-Of-Day maintenance and Finalization 9c then run `cargo clean` —
# which removes the target directory wholesale. Measured in a throwaway crate
# rather than assumed:
#
#     before: target/metrics=1  .cache/metrics=1
#     cargo clean
#     after:  target/metrics=0  .cache/metrics=1
#
# Not hypothetical: macuahuitl's `target/` went 24 GiB -> 31 GiB inside ONE
# cycle of gate runs, against that 40 GiB threshold.
#
# The cost is worse than a deleted file. `flow:` reports a ROLLING average whose
# value IS its length, and a reset on routine GC is INDISTINGUISHABLE from the
# documented one-time migration below — so a reader months from now sees
# `source=absent`, remembers the migration note, and shrugs at a sweep that just
# ate the series.
#
# The default deliberately does NOT vary by platform, though the bug it fixes is
# Windows-only. A path that differs by lane is the shape that produced three
# defects in eight hours on 2026-08-26 (`ps -o ppid=` absent on MSYS, GNU-only
# `du -sb`, GNU-only `\S`), and it would mean the next person debugging metrics
# must first work out which lane they are on.
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
        && mkdir -p "$_mdl_root/.cache/metrics" 2>/dev/null; then
        printf '%s/.cache/metrics/%s' "$_mdl_root" "$_mdl_base"
    else
        printf '/tmp/%s' "$_mdl_base"
    fi
}
