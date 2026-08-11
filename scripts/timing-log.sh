#!/usr/bin/env bash
# Shared build/test/litmus DURATION-telemetry helper (packet 682-emvg).
# @trace spec:methodology-accountability
# @trace order:682-emvg
#
# ONE JSONL line per timed heavy step, appended so a cycle can see WHERE time
# goes — "time spent building, testing" is the most likely bottleneck and was
# until now invisible. The sibling rungs are mcp-usage-log.sh (per-call MCP
# volume, 682-m8ek) and cycle-metrics.sh --emit-flow (per-cycle packet flow,
# 682-epud); this is the per-step wall-clock rung. cycle-metrics.sh reports the
# rolling view on its `timing:` line.
#
# RECORD GRAMMAR (pinned; agents/CI branch on the keys, never on prose):
#   {"ts":<utc>,"host":<h>,"step":<name>,"phase":<name>,"duration_ms":<n>,"exit":<n>}
# Written by cycle-metrics.sh --emit-timing (mirrors --emit-flow); this file
# supplies only the portable clock and a thin best-effort wrapper around it.
#
# BEST-EFFORT BY CONSTRUCTION, exactly like mcp-usage-log.sh: a timing failure
# must NEVER change the wrapped step's exit code or output. Every call is wrapped
# so a full disk, a read-only path, or an absent `date` cannot take down the
# build/test/litmus step being measured. A metric that can break what it measures
# is worse than none.

# Portable millisecond clock. `date +%s%3N` is GNU-only; on a host without it
# (macOS/BSD) the %3N is emitted literally, so detect a non-numeric result and
# fall back to whole seconds * 1000. Always prints a bare integer.
timing_now_ms() {
    local _n
    _n="$(date +%s%3N 2>/dev/null)"
    case "$_n" in
        '' | *[!0-9]*) date +%s 2>/dev/null | awk '{printf "%d000", $1}' 2>/dev/null || echo 0 ;;
        *) printf '%s' "$_n" ;;
    esac
}

# timing_emit <step> <phase> <t0_ms> <exit_code>
# Computes duration = now - t0 and appends one record via cycle-metrics.sh
# --emit-timing. Returns 0 unconditionally so `set -e` callers are safe and the
# wrapped step's own exit code is never disturbed.
timing_emit() {
    local _step="${1:-unknown}" _phase="${2:-unknown}" _t0="${3:-0}" _rc="${4:-0}"
    {
        local _dir _cm _now _dur _host
        _dir="${BASH_SOURCE[0]%/*}"
        _cm="$_dir/cycle-metrics.sh"
        _now="$(timing_now_ms)"
        case "$_t0" in '' | *[!0-9]*) _t0=0 ;; esac
        _dur=$((_now - _t0))
        [ "$_dur" -ge 0 ] 2>/dev/null || _dur=0
        _host="${TILLANDSIAS_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}"
        if [ -x "$_cm" ] || [ -r "$_cm" ]; then
            bash "$_cm" --emit-timing \
                step="$_step" phase="$_phase" duration_ms="$_dur" exit="$_rc" \
                host="$_host" >/dev/null 2>&1 || true
        fi
    } 2>/dev/null || true
    return 0
}

# When a caller could not source this file (path skew), it defines no-op
# fallbacks with the same names so call sites stay unconditional and set -e-safe:
#   . "${BASH_SOURCE[0]%/*}/timing-log.sh" 2>/dev/null || true
#   command -v timing_emit >/dev/null 2>&1 || { timing_now_ms(){ echo 0; }; timing_emit(){ return 0; }; }
:
