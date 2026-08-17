#!/usr/bin/env bash
# freshness: added 2026-08-17 windows-yolanda (order 801-qasc)
# @trace order:801-qasc, order:719-546b-3
# @trace spec:methodology-accountability
#
# check-daily-maintenance.sh — make the Start-Of-Day gate FALSIFIABLE.
#
# THE DEFECT THIS CLOSES
#
# The meta-orchestration skill has said, since 2026-08-13, that the Start Of Day
# gate is "idempotent and cheap when already done today — gate it on a
# `.last-daily-maintenance` marker under the cache dir; skip the body if the
# marker is from today", and methodology.yaml
# (development_environment_lifecycle.start_of_day_maintenance) says the same.
#
# Nothing wrote that marker. Nothing read it. It existed only as prose, on every
# host, for four days:
#
#   2026-08-14  a linux-immutable cycle noticed it out loud —
#               "a `.last-daily-maintenance` marker that nothing in the repo
#               writes" (plan/loop_status.d/20260814t232933z-…-linux-immutable.md)
#   2026-08-16  a windows cycle inherited "already stamped today" from its brief,
#               skipped the body, and could not confirm the premise
#   2026-08-17  the next windows cycle found no marker anywhere on the host
#
# So "did today's gate run?" had NO answer — not "no", which is actionable, but
# no answer at all. A gate whose execution cannot be observed is indistinguishable
# from a gate that never runs, and the cheapest way to satisfy it is to skip it,
# which is what happened. This is the same shape as the MCP probe reporting on a
# handshake nobody consumes and the mo-full marker that no lane checked: a
# guard only an attentive agent honours is a suggestion.
#
# WHAT IS AND IS NOT PROVEN HERE, stated plainly
#
# This answers "was the gate STAMPED today, and with what". It does not — and
# from a marker file cannot — prove the stamped steps did what they claim; that
# is the same limit `stamp` carries in check-windows-only-sources-verified.sh.
# What it removes is the unfalsifiable state: after this, "the gate ran" is a
# claim with a date, a host, and a named step list attached, and its absence is
# a verdict (`due:no-marker`) rather than silence. `--steps` is therefore
# MANDATORY and refused when empty: an evidence-free stamp would restore exactly
# the unfalsifiability being removed, one level up.
#
# GRAMMAR (exactly one line on stdout)
#   ok:daily-maintenance-current:<YYYY-MM-DD>    today's gate ran (exit 0)
#   ok:daily-maintenance-stamped:<YYYY-MM-DD>    `stamp` recorded it (exit 0)
#   skip:forge-exempt                            ephemeral forge (exit 0)
#   due:no-marker                                never stamped here (exit 1)
#   due:stale:<YYYY-MM-DD>                       last stamp predates today (exit 1)
#   due:unreadable-marker                        marker present but unparseable (exit 1)
#   refused:stamp-needs-steps                    `stamp` without --steps (exit 2)
#
# EXIT CODE IS LOAD-BEARING here, unlike the windows-only report: the caller is
# the skill's own gate deciding whether to run the body, so `if
# scripts/check-daily-maintenance.sh >/dev/null; then skip-body; fi` must be a
# correct implementation of the rule as written.
#
# A LOCAL day, not a UTC one — the rule is "once per local day (and on the first
# cycle after a restart)", and an operator's day boundary is the one on their
# wall clock. The marker records both, so a reader can tell them apart. This
# host is UTC-7, where a UTC-day gate would flip mid-afternoon.
#
# Seams (used by the fixture):
#   TILLANDSIAS_DAILY_MAINTENANCE_MARKER  marker path
#   TILLANDSIAS_DAILY_MAINTENANCE_TODAY   force "today" (YYYY-MM-DD)
#   TILLANDSIAS_HOST_KIND                 `forge` exempts the whole gate

set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"
MARKER="${TILLANDSIAS_DAILY_MAINTENANCE_MARKER:-$CACHE_DIR/.last-daily-maintenance}"
TODAY="${TILLANDSIAS_DAILY_MAINTENANCE_TODAY:-$(date +%Y-%m-%d 2>/dev/null || echo unknown)}"

# Ephemeral forges discard their substrate on teardown, so they have nothing to
# garbage-collect and must not be nagged. Exit 0: nothing is due.
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    echo "skip:forge-exempt"
    exit 0
fi

marker_date() {
    [ -f "$MARKER" ] || return 1
    # `date=YYYY-MM-DD` on any line. Tolerant of extra fields and of ordering so
    # the record can grow without breaking readers.
    sed -n 's/.*\bdate=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' \
        "$MARKER" 2>/dev/null | grep -m1 . || return 1
}

case "${1:-check}" in
    stamp)
        steps=""
        host=""
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --steps) steps="${2:-}"; shift 2 || shift ;;
                --host)  host="${2:-}"; shift 2 || shift ;;
                *) shift ;;
            esac
        done
        if [ -z "$steps" ]; then
            # An evidence-free stamp is the unfalsifiability this file removes,
            # reintroduced one level up. Refuse it, and print the argv that
            # works (order 801-ajcd's lesson: a refusal must parse as the
            # command it demands).
            echo "refused:stamp-needs-steps:usage: check-daily-maintenance.sh stamp --steps <csv-of-what-actually-ran> [--host <host>]; a stamp with no named steps records that something happened without recording what"
            exit 2
        fi
        [ -n "$host" ] || host="$(uname -n 2>/dev/null || echo unknown)"
        mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
        {
            printf 'date=%s utc=%s host=%s steps=%s\n' \
                "$TODAY" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
                "$host" \
                "$steps"
        } > "$MARKER" 2>/dev/null || {
            # Unwritable cache dir is a real failure here: silently "succeeding"
            # would leave the next cycle reading due: forever with no reason.
            echo "due:unreadable-marker"
            exit 1
        }
        echo "ok:daily-maintenance-stamped:$TODAY"
        exit 0
        ;;
    check)
        if [ ! -f "$MARKER" ]; then
            echo "due:no-marker"
            exit 1
        fi
        last="$(marker_date)" || last=""
        if [ -z "$last" ]; then
            # Present but unparseable. NOT ok: a corrupt marker read as current
            # is precisely the false-green this check exists to make impossible.
            echo "due:unreadable-marker"
            exit 1
        fi
        if [ "$last" = "$TODAY" ]; then
            echo "ok:daily-maintenance-current:$TODAY"
            exit 0
        fi
        echo "due:stale:$last"
        exit 1
        ;;
    show)
        # Not part of the pinned grammar — a human affordance for "what did the
        # last gate actually claim to do".
        [ -f "$MARKER" ] && cat "$MARKER" || echo "(no marker at $MARKER)"
        exit 0
        ;;
    fixture)
        _fx_fail=0
        _fx_dir="$(mktemp -d)"
        _fx_self="$0"
        _fx_marker="$_fx_dir/.last-daily-maintenance"
        _run() {
            TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$_fx_marker" \
            TILLANDSIAS_DAILY_MAINTENANCE_TODAY="2026-08-17" \
            TILLANDSIAS_HOST_KIND="${_FX_HOST_KIND:-}" \
                bash "$_fx_self" "$@"
        }
        _expect() {
            _n="$1"; _want_v="$2"; _want_rc="$3"; shift 3
            _got_v="$(_run "$@" 2>/dev/null)"; _got_rc=$?
            if [ "$_got_v" = "$_want_v" ] && [ "$_got_rc" = "$_want_rc" ]; then
                echo "ok: $_n ($_got_v rc=$_got_rc)"
            else
                echo "FAIL: $_n expected '$_want_v' rc=$_want_rc, got '$_got_v' rc=$_got_rc"
                _fx_fail=1
            fi
        }

        # 1. THE STATE THIS WHOLE FILE EXISTS FOR: no marker is a VERDICT with a
        #    non-zero exit, not silence. This is what every host was in on
        #    2026-08-17, reported as nothing at all.
        _expect "no-marker-is-a-verdict-not-silence" "due:no-marker" 1 check

        # 2. An evidence-free stamp is refused, and the refusal names the argv
        #    that works (order 801-ajcd).
        _got="$(_run stamp 2>/dev/null)"
        case "$_got" in
            refused:stamp-needs-steps:usage:*) echo "ok: stamp-without-steps-is-refused" ;;
            *) echo "FAIL: stamp without --steps expected a refusal naming its usage, got '$_got'"; _fx_fail=1 ;;
        esac
        [ -f "$_fx_marker" ] && { echo "FAIL: a refused stamp must not write the marker"; _fx_fail=1; }

        # 3. A stamp with named steps records the day and reads back current.
        _expect "stamp-records-today" "ok:daily-maintenance-stamped:2026-08-17" 0 \
            stamp --steps cargo-gc,podman-prune --host fixture
        _expect "stamped-today-reads-current" "ok:daily-maintenance-current:2026-08-17" 0 check
        if grep -q 'steps=cargo-gc,podman-prune' "$_fx_marker" 2>/dev/null \
           && grep -q 'host=fixture' "$_fx_marker" 2>/dev/null; then
            echo "ok: marker-carries-the-named-steps-and-host"
        else
            echo "FAIL: marker lost its steps/host fields:"; cat "$_fx_marker"; _fx_fail=1
        fi

        # 4. NEGATIVE CONTROL: yesterday's stamp is DUE, not current. Without
        #    this the check could pass case 3 by reporting ok for any marker at
        #    all — the exact "already stamped" premise a cycle inherited and
        #    could not falsify.
        printf 'date=2026-08-16 utc=2026-08-16T12:00:00Z host=fixture steps=x\n' > "$_fx_marker"
        _expect "yesterdays-stamp-is-due-not-current" "due:stale:2026-08-16" 1 check

        # 5. NEGATIVE CONTROL: a corrupt marker is DUE, never ok. A present-but-
        #    garbage file read as current is the false green this replaces.
        printf 'this is not a marker\n' > "$_fx_marker"
        _expect "corrupt-marker-is-due-not-ok" "due:unreadable-marker" 1 check

        # 6. Ephemeral forges are exempt (they discard their substrate).
        _FX_HOST_KIND=forge _expect "forge-is-exempt" "skip:forge-exempt" 0 check
        unset _FX_HOST_KIND

        # 7. Grammar: exactly one well-formed line, in every state above.
        _lines=0
        rm -f "$_fx_marker"
        for _st in check "stamp --steps a" check; do
            # shellcheck disable=SC2086
            _n="$(_run $_st 2>/dev/null | grep -cE '^(ok:daily-maintenance-(current|stamped):[0-9]{4}-[0-9]{2}-[0-9]{2}|skip:forge-exempt|due:(no-marker|unreadable-marker|stale:[0-9]{4}-[0-9]{2}-[0-9]{2}))$')"
            _lines=$((_lines + _n))
        done
        if [ "$_lines" = "3" ]; then
            echo "ok: grammar-exactly-one-line-per-invocation"
        else
            echo "FAIL: grammar expected 3 well-formed lines across 3 invocations, got $_lines"
            _fx_fail=1
        fi

        rm -rf "$_fx_dir"
        [ "$_fx_fail" = 0 ] && echo "ok:daily-maintenance-gate-fixture:7"
        exit "$_fx_fail"
        ;;
    *)
        echo "usage: check-daily-maintenance.sh [check|stamp --steps <csv> [--host <h>]|show|fixture]" >&2
        exit 2
        ;;
esac
