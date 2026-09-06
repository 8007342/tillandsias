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

# Absolute directory of THIS file, resolved ONCE at source time (697-s3by).
#
# `timing_emit` used to resolve its sibling `cycle-metrics.sh` at CALL time from
# `${BASH_SOURCE[0]%/*}`. That is the path this file was SOURCED with, and
# callers legitimately source it relatively — `run-litmus-test.sh:70` uses
# `$(dirname "${BASH_SOURCE[0]}")/timing-log.sh`, which is `./timing-log.sh`
# whenever that script is itself invoked by a relative path. The prefix strip
# then yields `_dir=.`, `_cm=./cycle-metrics.sh`, and the file is unreadable
# from whatever CWD the build happens to be in — so the shell-out never ran and
# the record was silently dropped.
#
# Silently, because the whole body is `{ … } 2>/dev/null || true; return 0` —
# correct for the "must never break the step it measures" contract, and exactly
# why this went unnoticed: `timing:` read `source=absent` on every cycle while
# `build.sh --check` ran five times in one session. Measured live 2026-08-12:
# `_dir=.` / `readable=no`.
#
# Resolving here, once, makes the lookup independent of both the CWD and of how
# the sourcing script was invoked. `cd … && pwd` yields an absolute path; if
# even that fails the value stays empty and the existing readability guard keeps
# the call harmless.
TILLANDSIAS_TIMING_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"

# Portable millisecond clock. `date +%s%3N` is GNU-only; on a host without it
# (macOS/BSD) the %3N is emitted literally, so detect a non-numeric result and
# fall back to whole seconds * 1000. Always prints a bare integer.
timing_now_ms() {
    local _n
    _n="$(date +%s%3N 2>/dev/null)" # gnu-date: ok (digit-validated by the case below; degrades to seconds*1000)
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
        # 697-s3by: use the absolute directory captured at SOURCE time, not a
        # call-time strip of BASH_SOURCE, which resolved to "." for relatively
        # sourced callers and made cycle-metrics.sh unreadable.
        _dir="${TILLANDSIAS_TIMING_LOG_DIR:-${BASH_SOURCE[0]%/*}}"
        _cm="$_dir/cycle-metrics.sh"
        _now="$(timing_now_ms)"
        case "$_t0" in '' | *[!0-9]*) _t0=0 ;; esac
        # 693-tf79: a zero/absent start time makes `_now - _t0` equal `_now`,
        # i.e. an absolute epoch-ms (~1.78e12 = a ~56-year "duration"), not an
        # elapsed time. That happens when the caller captured t0 with the no-op
        # stub `timing_now_ms(){ echo 0; }` (path-skew fallback) or passed
        # nothing. Such a record is meaningless — skip it rather than poison the
        # rolling averages. Best-effort contract preserved: still return 0.
        if [ "$_t0" -eq 0 ] 2>/dev/null; then
            return 0
        fi
        _dur=$((_now - _t0))
        [ "$_dur" -ge 0 ] 2>/dev/null || _dur=0
        # Defense-in-depth: no single build/test/litmus step legitimately runs
        # longer than a day. A value that large means a bad start time slipped
        # through — drop it instead of emitting garbage.
        if [ "$_dur" -ge 86400000 ] 2>/dev/null; then
            return 0
        fi
        # ORDER 890-t9pu — `hostname` IS NOT ALWAYS PRESENT, and its absence was
        # silently renaming every record on this lane.
        #
        # MEASURED on yolanda 2026-08-25: 2977 records carrying host="unknown".
        # The cause is not a misconfiguration — the WSL2 build distro is a
        # Fedora *container image*, and minimal container images ship no
        # `hostname` binary at all (`command -v hostname` -> NONE). So the
        # substitution failed, `|| echo unknown` fired, and a rolling fleet-wide
        # view lost the one field it needs most: which machine produced the
        # number.
        #
        # `/etc/hostname` DOES read `Yolanda` inside that same distro, so the
        # information was there the whole time behind a probe that could not
        # reach it. Try the cheap in-shell answer first ($HOSTNAME, a bash
        # builtin), then the binary, then the file. "unknown" now means genuinely
        # unknown rather than "the tool was missing".
        _host="${TILLANDSIAS_HOST_ID:-}"
        [ -n "$_host" ] || _host="${HOSTNAME:-}"
        [ -n "$_host" ] || _host="$(hostname 2>/dev/null || true)"
        [ -n "$_host" ] || _host="$(cat /etc/hostname 2>/dev/null || true)"
        _host="$(printf '%s' "$_host" | tr -d '[:space:]')"
        [ -n "$_host" ] || _host="unknown"
        if [ -x "$_cm" ] || [ -r "$_cm" ]; then
            bash "$_cm" --emit-timing \
                step="$_step" phase="$_phase" duration_ms="$_dur" exit="$_rc" \
                host="$_host" >/dev/null 2>&1 || true
        fi
    } 2>/dev/null || true
    return 0
}

# ── ORDER 1026-ps4n: a record that outlives its supervisor ──────────────────
#
# `timing_emit` runs AFTER the step it measures, in the shell that launched it.
# If that shell dies mid-step the record is never written, and the log is
# SILENT about a step that ran — indistinguishable from a step that never
# started.
#
# MEASURED on pirria 2026-09-04: the agent harness killed the smoke's wrapper
# mid-forge-lane for host memory pressure ("system is running low on memory").
# No kernel oom-kill in journalctl; all six enclave containers including
# inference survived and were healthy 56 minutes later. Only the bash wrapper
# died. The same lane had completed in 71m30s that morning, so the condition is
# MARGINAL rather than reliable — which is worse, because the floor's LONGEST
# and most valuable measurement is the one least likely to be captured, and it
# fails intermittently.
#
# THE HONEST OUTCOME OF THAT RUN WAS A GAP, and it should stay honest: a
# fabricated duration would have measured when the wrapper was killed rather
# than when the lane finished, and any exit code would have blamed the product
# for a harness kill. In a log built to decide what to memoise, a wrong number
# sits in the rolling averages forever and nobody can tell it apart. So this
# does NOT invent the missing measurement. It makes the ABSENCE self-describing.
#
# THE SHAPE. `timing_begin` writes a stamp to disk before the step runs;
# `timing_commit` emits the real record and removes the stamp; `timing_reap`
# finds stamps whose writer is gone and emits a record under a DIFFERENT STEP
# NAME (`<step>-supervisor-lost`) carrying the elapsed time as a LOWER BOUND.
# The distinct name is the whole safety property: the recurrence rung groups by
# step, so a lost-supervisor record can never be averaged into the real step's
# timings, and `repeat:`/`recur:` will show it as its own line — visible, and
# never silently inflating what it is not.
#
# A stamp is reaped only when its writer PID is gone, so a lane still running
# under a live supervisor is never reaped out from under itself.

timing_stamp_dir() {
    local _root
    _root="${TILLANDSIAS_TIMING_STAMP_DIR:-}"
    if [ -z "$_root" ]; then
        _root="$(cd -- "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd)/.cache/metrics/pending"
    fi
    mkdir -p "$_root" 2>/dev/null || return 1
    printf '%s' "$_root"
}

# timing_begin <step> <phase>  — record that a step STARTED, durably.
timing_begin() {
    {
        local _step="${1:-unknown}" _phase="${2:-unknown}" _dir
        _dir="$(timing_stamp_dir)" || return 0
        printf '%s %s %s %s\n' "$_step" "$_phase" "$(timing_now_ms)" "$$" \
            > "$_dir/${_step}.stamp" 2>/dev/null || true
    } 2>/dev/null || true
    return 0
}

# timing_commit <step> <phase> <t0_ms> <exit> — emit the real record, drop the
# stamp. Same arguments as timing_emit so a call site converts by renaming.
timing_commit() {
    timing_emit "${1:-unknown}" "${2:-unknown}" "${3:-0}" "${4:-0}" || true
    { local _dir; _dir="$(timing_stamp_dir)" && rm -f "$_dir/${1:-unknown}.stamp"; } 2>/dev/null || true
    return 0
}

# timing_reap — turn every orphaned stamp into a named-cause record. Safe to
# call at the START of any run: it reports on the PREVIOUS one.
timing_reap() {
    {
        local _dir _f _step _phase _t0 _pid _now
        _dir="$(timing_stamp_dir)" || return 0
        for _f in "$_dir"/*.stamp; do
            [ -f "$_f" ] || continue
            read -r _step _phase _t0 _pid < "$_f" || continue
            # A live writer means the step is still running: leave it alone.
            if [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null; then
                continue
            fi
            _now="$(timing_now_ms)"
            # Exit 1: the MEASUREMENT failed, not necessarily the work — the
            # step name says which, and the duration is a lower bound because
            # the true end time was never observed.
            timing_emit "${_step}-supervisor-lost" "${_phase:-unknown}" "${_t0:-0}" 1 || true
            rm -f "$_f" 2>/dev/null || true
        done
    } 2>/dev/null || true
    return 0
}

# When a caller could not source this file (path skew), it defines no-op
# fallbacks with the same names so call sites stay unconditional and set -e-safe:
#   . "${BASH_SOURCE[0]%/*}/timing-log.sh" 2>/dev/null || true
#   command -v timing_emit >/dev/null 2>&1 || { timing_now_ms(){ echo 0; }; timing_emit(){ return 0; }; }
# The 1026-ps4n helpers need the same treatment where they are used:
#   command -v timing_begin >/dev/null 2>&1 || { timing_begin(){ return 0; }; timing_commit(){ return 0; }; timing_reap(){ return 0; }; }
:
