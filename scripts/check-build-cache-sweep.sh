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
        # ORDER 905-97xh — UTC, like every other timestamp this project writes.
        #
        # `date +%Y-%m-%d` (local) alongside `date -u` (UTC) made ONE LINE OF
        # ONE FILE NAME TWO DIFFERENT DAYS. Measured on tlatoanis-macbook-air
        # 2026-08-26T06:09:41Z, which was 23:09 PDT on the 25th, stamping both
        # markers seconds apart:
        #
        #   build-cache:       date=2026-08-25 utc=2026-08-26T06:09:41Z
        #   daily-maintenance: date=2026-08-26 utc=2026-08-26T06:09:41Z
        #
        # The arithmetic was self-consistent (stamped local, compared local), so
        # this was never a wrong verdict — it was evidence a reader has to
        # reconcile before trusting, in a marker whose `--action` requirement
        # exists precisely so it reads as a record. It also broke on any host
        # that crosses DST or changes timezone, and this fleet spans PDT and
        # CEST.
        printf 'date=%s utc=%s host=%s action=%s\n' \
            "$(date -u +%Y-%m-%d)" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "${host:-unknown}" \
            "$action" > "$MARKER" || { echo "blocked:marker-unwritable"; exit 2; }
        echo "ok:build-cache-sweep-stamped:$(date -u +%Y-%m-%d)"
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
#
# `du -sk`, NOT `du -sb`. `-b` is GNU-only: BSD du REFUSES it outright, so on
# macOS the substitution below produced the empty string, the `|| bytes=0`
# fallback fired, and the SIZE TRIGGER WAS DEAD — a 15 GiB target/ measured as
# `bytes=0:gib=0` on this host, and only the marker-age trigger could ever fire.
# Exactly the family this file's own header cites (803-bqte's GNU-sed `\b`), in
# the file that documents it. `-k` is POSIX and reports KiB blocks on both.
#
# THE LITMUS DID NOT CATCH IT, and that is the more useful half of this note.
# `litmus:build-cache-sweep-trigger`'s size case sets
# TILLANDSIAS_BUILD_CACHE_MAX_GIB=0, so `gib >= 0` is true whatever `du`
# returned: it asserted the COMPARISON and never the MEASUREMENT. A test that
# pins a threshold check while the number feeding it is always zero passes
# identically on a working and a broken host. The suite now asserts a non-zero
# byte count for a file of known size, which fails on BSD without this fix.
if [ -d "$TARGET_DIR" ]; then
    kib="$(du -sk "$TARGET_DIR" 2>/dev/null | awk 'NR==1 {print $1}')"
    case "$kib" in
        ''|*[!0-9]*) kib=0 ;;
    esac
    bytes=$(( kib * 1024 ))
else
    bytes=0
fi
gib=$(( bytes / 1073741824 ))

mdate="$(marker_date || true)"
if [ -n "$mdate" ]; then
    mdays="$(_date_to_days "$mdate" 2>/dev/null || true)"
    # UTC on BOTH sides (905-97xh).
    #
    # THE MIGRATION EDGE, handled rather than asserted away. Markers stamped
    # before this change carry a LOCAL date. On a host EAST of UTC that date can
    # be TOMORROW in UTC terms — measured with TZ=Pacific/Kiritimati (UTC+14),
    # where the old stamp wrote `date=2026-08-27` while `utc=2026-08-26`. Naive
    # subtraction then yields age_days=-1, which this script's next branch
    # reports as `unreadable-marker` — a perfectly good marker declared corrupt,
    # and a full sweep prescribed for it.
    #
    # A marker one day in the future is a legacy local stamp, not corruption, so
    # clamp exactly that case to 0 (fresh). Anything further ahead is a real
    # anomaly — a badly wrong clock — and still falls through to the
    # unreadable-marker branch, because silently accepting an arbitrary future
    # date would disable the staleness trigger entirely.
    today_days="$(_date_to_days "$(date -u +%Y-%m-%d)" 2>/dev/null || true)"
    if [ -n "$mdays" ] && [ -n "$today_days" ]; then
        age_days=$(( today_days - mdays ))
        if [ "$age_days" -eq -1 ]; then
            age_days=0
        fi
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
    # ORDER 906-qi89 — A BOOKKEEPING ABSENCE IS NOT EVIDENCE OF BLOAT.
    #
    # The two triggers mean different things and the reason field already says
    # so: `over-size` is evidence of bloat, `stale-Nd` is evidence of neglect,
    # `no-marker` is evidence of NEITHER — only that this host has not stamped
    # before. Returning `due` for it prescribed `cargo clean`, which the policy
    # itself calls out as expensive and requires to be rare. Measured on
    # tlatoanis-macbook-air across three consecutive cycles: a full rebuild
    # prescribed at 18 GiB against a 40 GiB trigger, at 45% of the threshold.
    # A fresh host paid it on its FIRST cycle — the cycle where a warm cache is
    # worth the most.
    #
    # RESOLVED as exit-criterion (a): initialise and report not-due. The
    # alternative — stay due and document why a fresh host pays a sweep — was
    # rejected because there is no evidence to justify the cost.
    #
    # INITIALISING IS NOT MERELY THE CHEAP OPTION; IT CLOSES A REAL GAP. The
    # 14-day trigger exists to catch a host accumulating slowly WITHOUT
    # crossing 40 GiB. A never-stamped marker has no age, so that trigger could
    # never fire for such a host — leaving it at 39 GiB forever with no
    # periodic sweep. Starting the clock is what makes staleness live.
    #
    # THE STAMP MUST NOT LIE. It records that no reclaim ran and why, so nobody
    # reading the marker later mistakes an initialisation for a sweep — the
    # `--action` requirement exists for exactly that reason.
    if [ "$gib" -lt "$MAX_GIB" ]; then
        _init_action="initialised:NO-SWEEP-PERFORMED(${gib}GiB<${MAX_GIB}GiB);reason:trigger-was-marker-absent-not-size"
        mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
        if printf 'date=%s utc=%s host=%s action=%s\n' \
            "$(date -u +%Y-%m-%d)" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "$(hostname -s 2>/dev/null || echo unknown)" \
            "$_init_action" > "$MARKER" 2>/dev/null; then
            echo "ok:build-cache-sweep-not-due:bytes=${bytes}:gib=${gib}:marker=initialised:reason=no-marker-initialised-under-threshold"
            exit 0
        fi
        # Could not write: fall through to `due` rather than inventing a pass.
        # An uninitialisable marker is a real problem and must stay visible.
        echo "due:build-cache-sweep:bytes=${bytes}:gib=${gib}:marker=absent:reason=no-marker-uninitialisable"
        exit 1
    fi
    # Over the size threshold with no marker: the size trigger above already
    # returned. Unreachable in practice; kept so the branch is total.
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
