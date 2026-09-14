#!/usr/bin/env bash
# @trace order:890-27mv, spec:ci-release
#
# check-release-tier-freshness.sh — answer "when was the RELEASE tier last
# exercised on this host, and what was the verdict", without cutting a release.
#
# THE GAP THIS FILLS (890-27mv). The recurring loop gates on `./build.sh
# --check`; the release gates on `--ci-full`. run-litmus-test.sh is reached
# only from the --ci/--ci-full path, and target/convergence/check-logs.jsonl is
# written only by scripts/local-ci.sh. So the delta between the two tiers is
# never exercised between releases, accumulates silently, and is discharged all
# at once by whoever is trying to ship. Measured on yoga 2026-09-12:
# target/convergence/ held only the centicolon dashboard pair from 09-04 and NO
# check-logs.jsonl at all — the release tier has never run on this host. Not
# "failed quietly": never ran.
#
# THIS SCRIPT DOES NOT RUN THE TIER and deliberately does not gate the inner
# loop. 758-jw6v removed real cost from `--check` and the packet's own notes
# refuse a fix that puts it back; a gate that gets slow gets bypassed. This only
# READS the history the heavier tier already leaves behind, so it is cheap
# enough to call from anywhere.
#
# NEVER-RAN MUST NOT READ AS PASS. That is the negative control (criterion 4)
# and it is the whole point: a host that cannot run the heavier tier, or simply
# never has, must SAY SO. Every non-green outcome here exits non-zero, and the
# could-not-run channel keeps 965-sxec's grammar — exit 3 means the instrument
# could not answer, never that the answer was good.
#
# Exit codes:  0 exercised, recent, all green
#              1 a real, loud answer that is not green (never run / stale / red)
#              3 could-not-run — this host cannot even determine it
#
# Tokens on stdout are stable and meant to be grepped by a caller.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "could-not-run:release-tier:repo root unreachable"; exit 3; }

INDEX="${TILLANDSIAS_CHECK_LOG_INDEX:-target/convergence/check-logs.jsonl}"
MAX_AGE_DAYS="${TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS:-7}"

# ── Age arithmetic WITHOUT `date -d` ───────────────────────────────────────
# `date -d` and `touch -d` are GNU-only (1129-4su6) and this script has to be
# readable on the macOS hosts too. days_from_civil is the standard civil-date
# algorithm in pure shell arithmetic, so it needs no date(1) flags at all.
days_from_civil() {
    local y="$1" m="$2" d="$3" era yoe doy doe
    [ "$m" -le 2 ] && y=$((y - 1))
    if [ "$y" -ge 0 ]; then era=$((y / 400)); else era=$((((y - 399)) / 400)); fi
    yoe=$((y - era * 400))
    if [ "$m" -gt 2 ]; then doy=$(((153 * (m - 3) + 2) / 5 + d - 1))
    else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    printf '%s\n' $((era * 146097 + doe - 719468))
}

# local-ci stamps the moment into CI_RUN_ID as local-ci-YYYYMMDDTHHMMSSZ. THERE
# IS NO ts FIELD in the record (ci_run_id, ci_phase, check_id, status,
# source_log, archived_log, sha256, duration_ms) — read the writer before
# trusting a field name; a guessed `ts` here would have silently matched
# nothing and reported every run as unparseable.
epoch_of_run_id() {
    local id="$1" stamp
    stamp="${id#local-ci-}"
    case "$stamp" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
        *) return 1 ;;
    esac
    local Y="${stamp:0:4}" M="${stamp:4:2}" D="${stamp:6:2}"
    local h="${stamp:9:2}" mi="${stamp:11:2}" s="${stamp:13:2}"
    # 10# so a leading zero is not read as octal.
    local days; days="$(days_from_civil "$((10#$Y))" "$((10#$M))" "$((10#$D))")" || return 1
    printf '%s\n' $((days * 86400 + 10#$h * 3600 + 10#$mi * 60 + 10#$s))
}

field_of() { # field_of <record> <name>
    case "$1" in
        *"\"$2\":\""*) printf '%s\n' "${1#*\"$2\":\"}" | head -1 | sed 's/".*//' ;;
        *) return 1 ;;
    esac
}

# ── Is there any history at all? ───────────────────────────────────────────
if [ ! -f "$INDEX" ]; then
    echo "never:release-tier:no $INDEX on this host — the release tier has NEVER been exercised here"
    echo "  This is an answer, not a failure to get one: nothing has ever written a"
    echo "  release-tier record on this host. Run scripts/local-ci.sh (or ./build.sh"
    echo "  --ci-full) to create one. It is NOT a statement that the tier would pass."
    exit 1
fi
if [ ! -s "$INDEX" ]; then
    echo "never:release-tier:$INDEX is empty — a run was started but recorded no check"
    exit 1
fi

# ── ORDER 1174-6r4k — PICK THE NEWEST FULL-TIER RUN, NOT THE NEWEST RUN ────
#
# This used to read `tail -1` and take whatever run wrote last. A diagnostic
# `scripts/local-ci.sh --phase pre-build` — the cheapest way to reproduce a
# gate-only red, and what it was used for during the v56.9.13.1 cut — appends a
# PARTIAL run to the same index. Green, it would read fresh:release-tier and the
# 09:09 daily exercise (890-27mv) would skip the real tier on the strength of a
# run that never touched post-build or runtime. Red, it would report a red the
# tier never produced. Measured on macuahuitl 2026-09-13 23:39Z:
# local-ci-20260913T233926Z, a pre-build-only run, became the newest record.
#
# WHAT COUNTS AS FULL TIER, from the writer's own vocabulary: local-ci.sh sets
# CI_PHASE="all" for a whole run and to the phase name for `--phase <p>`. So a
# run is full-tier if its records say `all`, or if between them they cover
# pre-build AND post-build AND runtime — a run that did every phase separately
# has exercised the tier even though no single record says so.
#
# THE dispatch=ci-full MARKER THE ROW MENTIONS DOES NOT EXIST IN THIS INDEX, and
# it is recorded here rather than assumed: build.sh's _stamp_dispatch writes
# `dispatch` into the GATE STAMP, and local-ci.sh's check-log record carries
# ci_run_id, ci_phase, check_id, status, source_log, archived_log, sha256 and
# duration_ms — no dispatch field reaches this file. Phase coverage is the
# discriminator that is actually available; adding a marker to the writer is a
# separate change and is not smuggled in here.
_run_ids=""          # every run id, in order of first appearance
_full_runs=""        # those whose phase set covers the tier
_phases_for() {      # _phases_for <run-id> -> space-separated phase set
    local _id="$1" _p _seen=""
    while IFS= read -r _r; do
        case "$_r" in *"\"ci_run_id\":\"$_id\""*) ;; *) continue ;; esac
        _p="$(field_of "$_r" ci_phase)" || _p=""
        [ -n "$_p" ] || continue
        case " $_seen " in *" $_p "*) ;; *) _seen="$_seen $_p" ;; esac
    done < "$INDEX"
    printf '%s' "$_seen"
}
while IFS= read -r _rec; do
    [ -n "$_rec" ] || continue
    _id="$(field_of "$_rec" ci_run_id)" || continue
    case " $_run_ids " in *" $_id "*) continue ;; esac
    _run_ids="$_run_ids $_id"
done < "$INDEX"
for _id in $_run_ids; do
    _set="$(_phases_for "$_id")"
    case " $_set " in
        *" all "*) _full_runs="$_full_runs $_id"; continue ;;
    esac
    case " $_set " in
        *" pre-build "*)
            case " $_set " in *" post-build "*)
                case " $_set " in *" runtime "*) _full_runs="$_full_runs $_id" ;; esac ;;
            esac ;;
    esac
done

LAST_RUN=""
for _id in $_full_runs; do LAST_RUN="$_id"; done
if [ -z "$LAST_RUN" ]; then
    # NOT "fresh". Every run on record is partial, so this host has no
    # release-tier answer at all — the same fact the no-index branch reports,
    # reached a different way, and reporting it as green would be the defect
    # this order exists to remove.
    _newest=""; for _id in $_run_ids; do _newest="$_id"; done
    echo "never:release-tier:no FULL-tier run in $INDEX — the newest run $_newest covers only [$(_phases_for "$_newest")]"
    echo "  A phase-only run is not a release-tier answer (1174-6r4k). Run"
    echo "  scripts/local-ci.sh (all phases) or ./build.sh --ci-full to produce one."
    exit 1
fi

# NAME THE RUNS BEING IGNORED. Silence here would look identical to "there was
# nothing newer", and the whole point is that something newer was deliberately
# not used.
_skipped=""
_after=0
for _id in $_run_ids; do
    [ "$_after" -eq 1 ] && case " $_full_runs " in
        *" $_id "*) ;;
        *) _skipped="${_skipped:+$_skipped }$_id" ;;
    esac
    [ "$_id" = "$LAST_RUN" ] && _after=1
done
for _id in $_skipped; do
    echo "skip:phase-only-run:$_id (newer than $LAST_RUN, covers only [$(_phases_for "$_id")] — not a release-tier answer)"
done

# ── Verdict over the WHOLE last run, not just its last line ────────────────
# A tail -1 verdict would report the status of one check and call it the run's.
pass=0; fail=0; skip=0; other=0
while IFS= read -r _rec; do
    [ -n "$_rec" ] || continue
    case "$_rec" in *"\"ci_run_id\":\"$LAST_RUN\""*) ;; *) continue ;; esac
    _st="$(field_of "$_rec" status)" || _st=""
    case "$_st" in
        pass|passed|ok) pass=$((pass + 1)) ;;
        fail|failed|red) fail=$((fail + 1)) ;;
        skip|skipped) skip=$((skip + 1)) ;;
        *) other=$((other + 1)) ;;
    esac
done < "$INDEX"

total=$((pass + fail + skip + other))

if ! LAST_EPOCH="$(epoch_of_run_id "$LAST_RUN")"; then
    echo "could-not-run:release-tier:cannot read a timestamp out of ci_run_id '$LAST_RUN'"
    echo "  Verdict over that run was ${pass} pass / ${fail} fail / ${skip} skip, but HOW OLD"
    echo "  it is cannot be determined, so freshness is unanswerable."
    exit 3
fi
NOW_EPOCH="$(date -u +%s 2>/dev/null)" || {
    echo "could-not-run:release-tier:date(1) would not give an epoch"
    exit 3
}
AGE_DAYS=$(((NOW_EPOCH - LAST_EPOCH) / 86400))
[ "$AGE_DAYS" -lt 0 ] && AGE_DAYS=0

echo "release-tier last exercised here: $LAST_RUN (${AGE_DAYS}d ago)"
echo "  verdict over that run: ${pass} pass, ${fail} fail, ${skip} skip, ${other} unrecognised, ${total} records"

if [ "$fail" -gt 0 ]; then
    echo "red:release-tier:$fail failing check(s) in $LAST_RUN — the last release-tier answer on this host was RED"
    exit 1
fi
if [ "$AGE_DAYS" -gt "$MAX_AGE_DAYS" ]; then
    echo "stale:release-tier:${AGE_DAYS}d exceeds ${MAX_AGE_DAYS}d — green, but too old to be evidence about this tree"
    exit 1
fi
echo "ok:release-tier-fresh:$LAST_RUN:${AGE_DAYS}d:${pass}/${total}"
exit 0
