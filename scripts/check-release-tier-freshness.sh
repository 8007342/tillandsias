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

LAST_RECORD="$(tail -1 "$INDEX")"
LAST_RUN="$(field_of "$LAST_RECORD" ci_run_id)" || {
    echo "could-not-run:release-tier:the last record in $INDEX carries no ci_run_id"
    exit 3
}

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
