#!/usr/bin/env bash
# @trace spec:meta-orchestration
# =============================================================================
# check-build-cache-sweep.sh — order 709-in2f.
#
# Durable hosts accumulate a large disposable build cache (63 GiB measured on
# the linux dev host 2026-08-12). methodology.yaml `build_cache_hygiene` says a
# durable host reclaims it at CYCLE END when genuinely bloated OR stale, and
# NOT on every cycle — a full `cargo clean` forces a full rebuild next cycle,
# so the sweep must be rare.
#
# UNTIL NOW NOTHING IMPLEMENTED THAT. methodology.yaml's rule ended
# "Implemented + litmus-pinned by the ledger packet
# build-cache-sweep-on-durable-hosts", and that packet (709-in2f) sat `ready`:
# no script, no marker, no litmus. The policy was prose that read like a
# mechanism, which is the same shape as an unbound litmus (660-ryhn) or an
# unwritten daily-maintenance marker (801-qasc) — a rule nobody can observe is
# indistinguishable from one that never runs.
#
# EXIT POLARITY, and read it before wiring anything to this: `check` exits 0
# when the sweep is NOT due, matching check-deslop-due.sh and
# check-daily-maintenance.sh. The actionable state is the non-zero one, so a
# healthy steady state stays quiet under `set -e`. Branch on the verdict TOKEN
# (`sweep-due` / `sweep-not-due`), which cannot be inverted by a copy-paste.
#
# Verdict grammar, one line, nothing else on stdout:
#   ok:build-cache-sweep-not-due:bytes=N:gib=N:marker=DATE|absent:reason=R   exit 0
#   due:build-cache-sweep:bytes=N:gib=N:marker=DATE|absent:reason=R          exit 1
#   skip:forge-exempt                                                        exit 0
#   blocked:<reason>                                                         exit 2
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${TILLANDSIAS_BUILD_CACHE_DIR:-$ROOT/target}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"
MARKER="${TILLANDSIAS_BUILD_CACHE_SWEEP_MARKER:-$CACHE_DIR/.last-build-cache-sweep}"

# Thresholds are methodology's, restated in ONE place each so this file and the
# rule cannot drift apart silently. If they ever disagree, methodology wins and
# this file is the stale one.
MAX_GIB="${TILLANDSIAS_BUILD_CACHE_MAX_GIB:-40}"
MAX_AGE_DAYS="${TILLANDSIAS_BUILD_CACHE_MAX_AGE_DAYS:-14}"

# Ephemeral forges discard target/ with the container, so a sweep there buys
# nothing and costs a full rebuild inside a short-lived cycle.
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    echo "skip:forge-exempt"
    exit 0
fi


# A plain YYYY-MM-DD to epoch-days, WITHOUT `date -d` (GNU) or `date -j -f`
# (BSD). Lifted from check-deslop-due.sh's `_iso_to_epoch`, and for the same
# reason it exists there: BSD `date` SUCCEEDS on `-d` with garbage output, so an
# exit-code guard cannot catch the difference and the failure is silent on
# macOS only. This family has already cost the project one cross-platform
# outage (the `\b` GNU-sed extension that made three markers write-only on
# macOS while every self-test passed on Linux — order 803-bqte).
# Days-from-civil is a few lines of arithmetic identical under gawk, mawk and
# the one-true-awk. Caught here by check-bash-dialect.sh (761-g36m) before it
# could reach a Mac.
_date_to_days() {
    awk -v s="$1" '
        function dfc(y, m, d,   era, yoe, doy, doe) {
            if (m <= 2) y -= 1
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        BEGIN {
            if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) exit 3
            printf "%d\n", dfc(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0)
        }'
}

marker_date() {
    [ -f "$MARKER" ] || return 1
    tr ' ' '\n' < "$MARKER" 2>/dev/null \
        | sed -n 's/^date=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
        | grep -m1 . || return 1
}

case "${1:-check}" in
    stamp)
        mkdir -p "$CACHE_DIR" 2>/dev/null || {
            echo "blocked:cache-dir-unwritable"; exit 2; }
        shift
        host=""; action=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --host)   host="${2:-}"; shift 2 || shift ;;
                --action) action="${2:-}"; shift 2 || shift ;;
                *) shift ;;
            esac
        done
        # An action is REQUIRED for the same reason check-daily-maintenance.sh
        # requires --steps: a stamp recording "something happened" without
        # recording WHAT restores the unfalsifiability one level up.
        if [ -z "$action" ]; then
            echo "blocked:stamp-needs-action" >&2
            echo "  usage: $0 stamp --host <host> --action 'cargo-clean:<result>,nix-gc:<result>'" >&2
            exit 2
        fi
        printf 'date=%s utc=%s host=%s action=%s\n' \
            "$(date +%Y-%m-%d)" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "${host:-unknown}" \
            "$action" > "$MARKER" || { echo "blocked:marker-unwritable"; exit 2; }
        echo "ok:build-cache-sweep-stamped:$(date +%Y-%m-%d)"
        exit 0
        ;;
    show)
        if [ -f "$MARKER" ]; then cat "$MARKER"; else echo "absent:$MARKER"; fi
        exit 0
        ;;
    check) ;;
    *) echo "blocked:unknown-subcommand:${1}"; exit 2 ;;
esac

# Size. A missing target/ is 0 bytes, not an error: a fresh checkout has not
# built yet and is emphatically not due for a sweep.
if [ -d "$TARGET_DIR" ]; then
    bytes="$(du -sb "$TARGET_DIR" 2>/dev/null | cut -f1)"
    [ -n "$bytes" ] || bytes=0
else
    bytes=0
fi
gib=$(( bytes / 1073741824 ))

mdate="$(marker_date || true)"
if [ -n "$mdate" ]; then
    mdays="$(_date_to_days "$mdate" 2>/dev/null || true)"
    today_days="$(_date_to_days "$(date +%Y-%m-%d)" 2>/dev/null || true)"
    if [ -n "$mdays" ] && [ -n "$today_days" ]; then
        age_days=$(( today_days - mdays ))
    else
        age_days=-1
    fi
    marker_field="$mdate"
else
    # DISTINGUISH the two absences. A marker file that exists but
    # carries no parseable `date=` is CORRUPT, not missing, and saying
    # `no-marker` about it sends the reader looking for a file that is
    # right there. Both are due — an unreadable prior sweep is not a
    # sweep — but the reason has to name what it found.
    if [ -f "$MARKER" ]; then
        marker_field="unreadable"
    else
        marker_field="absent"
    fi
    age_days=-1
fi

# Trigger, whichever comes first. An ABSENT marker is due — same fail-open-to-
# action convention as the daily gate: an unobservable prior sweep is not a
# sweep, and stamping it is the cheap way to make the next check meaningful.
if [ "$gib" -ge "$MAX_GIB" ]; then
    echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=${marker_field}:reason=over-size"
    exit 1
fi
if [ "$marker_field" = "unreadable" ]; then
    echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=unreadable:reason=unreadable-marker"
    exit 1
fi
if [ "$marker_field" = "absent" ]; then
    echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=absent:reason=no-marker"
    exit 1
fi
if [ "$age_days" -lt 0 ]; then
    echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=${marker_field}:reason=unreadable-marker"
    exit 1
fi
if [ "$age_days" -ge "$MAX_AGE_DAYS" ]; then
    echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=${marker_field}:reason=stale-${age_days}d"
    exit 1
fi

echo "ok:build-cache-sweep-not-due:bytes=${bytes}:gib=${gib}:marker=${marker_field}:reason=under-threshold-${age_days}d"
exit 0
