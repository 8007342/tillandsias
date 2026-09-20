#!/usr/bin/env bash
# @trace spec:ci-release, order:1313-w78k
#
# check-fragment-ts-skew.sh — refuse a fragment whose `ts:` is in the FUTURE
# against the pushing host's clock, and REPORT one that is in the past.
#
# WHY THIS EXISTS. `tillandsias-plan append-event` already refuses a ts more
# than 900 s from the host's clock:
#
#   error: --ts 2026-09-20T23:30:00Z disagrees with this host's clock
#          2026-09-20T18:19:51Z by 18609s (limit 900s) ... append-event refused
#
# A fragment written BY HAND as YAML goes through no such check. The parser, the
# plan-only lane and the fold all read `ts:` and none of them asks whether it is
# a time that has happened. So the limit protected only the path a careful agent
# was already on, and the careless path is the one that needed it.
#
# MEASURED on pirria 2026-09-20: six hand-written fragments in one session, five
# of them in the FUTURE, the worst by 4h49m against a real clock of 18:26:40Z.
# They were composed as plausible clock times rather than read from the clock.
# The coordinator's working notes ran an hour ahead of UTC the same day for the
# same reason. Two hosts, same day, same cause — a time composed instead of read.
#
# NOT TIDINESS: `ts` is what "stalest first" sorts on, what claim expiry reads,
# and what every recency claim over the ledger consumes. A future-dated event is
# the newest thing in the ledger until the clock catches up, and the records are
# permanent.
#
# THE RULE IS ASYMMETRIC, and deliberately (coordinator ruling, 2026-09-20):
#
#   FUTURE beyond the limit -> REFUSED, always. No declaration admits it. No
#   clock-correct writer produces a future timestamp, so it is never a backfill;
#   it is an invented time. `--backfill` stays what it is for the tool's own
#   writes and is not a way to push one of these through the lane.
#
#   PAST beyond the limit -> ACCEPTED, and the skew PRINTED. A delayed push is
#   real and common: lenovinha's seven fragments were written at 16:17Z and
#   folded at 19:00Z; yolanda's reach trunk hours after they are written.
#   Requiring a declaration for those would turn every relay fold into a refusal
#   or a ritual, and a ritual is a thing people learn to perform without reading.
#
# DIFF-SCOPED, the same construction as check-added-fragments-parse.sh (698-7n6q)
# and for the same reason: failing on any fragment anywhere would let one host's
# mistake turn every other host's gate red until someone else fixed it. You break
# it, your push fails; you inherit it, you are not even told.
set -uo pipefail

FRAG_DIR="plan/index.d"
LIMIT="${TILLANDSIAS_FRAGMENT_TS_SKEW_LIMIT:-900}"
base_ref="${TILLANDSIAS_FRAGMENT_PARSE_BASE:-origin/linux-next}"

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "skip:fragment-ts-skew:no-base-ref"
    echo "  note: base ref '$base_ref' unavailable — ts-skew enforcement skipped" >&2
    exit 0
fi

files="$(
    {
        git diff --name-only --diff-filter=AM "$base_ref" -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=AM -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
    } | sort -u
)"
[ -n "$files" ] || { echo "ok:fragment-ts-skew:0 checked"; exit 0; }

now="$(date -u +%s)"
checked=0; refused=0; past=0

# Portable epoch parse for an ISO-8601 Z timestamp. `date -d` is GNU-only and a
# BSD date (macOS, which pushes osx-next through this same hook) rejects it, so
# try GNU first and fall back to BSD's -j -f. If neither can read it, say so and
# do NOT refuse: an unparseable ts is check-added-fragments-parse.sh's business
# (720-24u6 already refuses a bare timestamp), and two checks refusing the same
# byte with different words is how an operator learns to ignore both.
_epoch() { # $1 = ISO8601 Z
    date -u -d "$1" +%s 2>/dev/null && return 0
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
    return 1
}

while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    while IFS= read -r stamp; do
        [ -n "$stamp" ] || continue
        e="$(_epoch "$stamp")" || { echo "note:fragment-ts-unreadable:$f:$stamp" >&2; continue; }
        checked=$((checked + 1))
        delta=$((e - now))
        if [ "$delta" -gt "$LIMIT" ]; then
            refused=$((refused + 1))
            {
                echo "violation:fragment-ts-future:$f"
                echo "  ts $stamp is ${delta}s AHEAD of this host's clock ($(date -u +%Y-%m-%dT%H:%M:%SZ)); limit ${LIMIT}s."
                echo "  A future timestamp is not a backfill — no clock-correct writer produces one."
                echo "  REMEDY: read the clock instead of composing a time:"
                echo "    date -u +%Y-%m-%dT%H:%M:%SZ"
                echo "  or let the tool write it: tillandsias-plan append-event ... (omit --ts)."
            } >&2
        elif [ "$delta" -lt "-$LIMIT" ]; then
            past=$((past + 1))
            echo "note:fragment-ts-past:$f:$(( -delta ))s"
        fi
    done <<EOF
$(grep -oE '"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$f" 2>/dev/null | tr -d '"')
EOF
done <<EOF
$files
EOF

if [ "$refused" -gt 0 ]; then
    echo "violation:fragment-ts-future:$refused" >&2
    exit 1
fi
echo "ok:fragment-ts-skew:$checked checked, $past past-noted"
