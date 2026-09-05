#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-stranded-in-progress.sh — report packets stuck in `in_progress`.
#
# Order 642-*.
#
# THE LEAK. A packet in `in_progress` is skipped by `ready` queries, so nobody
# claims it.
#
# CORRECTED 2026-08-31 (946-pdpi, measured): this said "invisible in BOTH
# directions ... burndown does not count it". The burndown half is false —
# `tillandsias-plan burndown <milestone>` lists in_progress children WITH their
# status. Only the ready/selector pool hides a claim, which is precisely why
# this sweep is the sole observer and why its predicate had to be right.
#
# Such a packet is neither work nor done. 23 were in that state when this was
# written (16 linux, 6 windows), the oldest at order 153.
#
# This is a DIFFERENT leak from 635-i6vm, and the guard written for that one
# cannot see it:
#
#   635-i6vm  completion WAS declared, and the G-Set fold discarded it.
#             check-fragment-status-loss.sh catches that.
#   this      completion was NEVER declared. 627-k4mz was filed
#             `status: in_progress`, the fix was written, reviewed and merged —
#             and no fragment ever said so. Nothing was discarded, so nothing
#             looks wrong.
#
# WHAT THIS DOES NOT DO. It does not close anything. Deciding a packet is
# finished requires checking its exit criteria against the tree, and an
# automated closer that guesses would silently mark unfinished work done — the
# most expensive possible version of this bug. It reports; owners close.
#
# GRAMMAR — one line per flagged packet, then one summary line:
#   ^stranded\t<order>\t<role>\t<packet_id>\tidle=<n>h$
#   ^unknown-age\t<order>\t<role>\t<packet_id>$
#   ^summary: (population=<n> in_progress=<n> stranded=<n> threshold_events=<n>|unavailable:<reason>)$
#
# `stranded` means IDLE PAST THE THRESHOLD (946-pdpi), not "has never had a
# progress event". `idle=<n>h` is on the row so the reader can judge without
# re-deriving it. `unknown-age` is its own class rather than a silent pass or a
# guessed flag — an unreadable age is not an absent one.
#
# POPULATION (order 831-ezea). Every check verdict names the size of the set it
# examined, so that a green cannot be misread as health over nothing. Here
# `population` is DELIBERATELY equal to `in_progress`, and that is the point
# rather than a redundancy: this sweep's population IS the in_progress set, so
# the number a reader saw as a clean finding ("nothing in progress — good") was
# always the denominator ("I examined nothing"). The field does not add a new
# number, it names the role of one that was already there. Anything that greps
# `stranded=0` as evidence of health must first read `population=`.
#
# An `unavailable:` verdict carries NO population field: the sweep did not look,
# so the denominator is unknown, not zero. Printing `population=0` there would
# be the same false all-clear the third verdict exists to prevent.
#
# `unavailable:<reason>` (702-68zj) is a THIRD verdict for "this sweep could not
# be computed" — no runnable plan binary, no jq, a failed or unparseable query.
# It is deliberately not an all-zero summary: reporting zero because the sweep
# could not look is how a stranded packet became invisible in a third way.
# Exit 0 always: this is an advisory report, not a gate. A packet legitimately
# in flight right now is indistinguishable from one abandoned an hour ago, so
# failing a build on it would block work for a state that is often correct.

set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# ORDER 702-68zj / 704-zcgi. The binary probe lives in one shared file, because
# three scripts independently wrote the same wrong version of it. Its rule: an
# executable BIT is a claim, RUNNING the binary is evidence. Testing the bit
# picked a Linux ELF sitting at ./target/release/tillandsias-plan on a shared
# Windows/WSL checkout, every query died with `Exec format error`, stderr was
# discarded, and empty output was counted as zero stranded packets — a clean
# all-clear while a stranded packet sat in the ledger.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""

# UNAVAILABLE is a THIRD verdict, not a quiet zero (702-68zj). This sweep exists
# to catch work that is invisible in both directions — `ready` queries skip an
# in_progress packet and burndown does not count it. Reporting zero because the
# sweep could not look makes that work invisible in a third way, and does it
# while printing the exact line an operator reads as "checked, nothing there".
# Same convention as verify:skip-stale-staging (447) and skip:no-tray-binary
# (620-duta). Exit stays 0: this is advisory, and an unavailable sweep is not a
# build failure.
[ -n "$PLAN" ] || {
    echo "summary: unavailable:no-runnable-plan-binary"
    exit 0
}

command -v jq >/dev/null 2>&1 || {
    echo "summary: unavailable:no-jq"
    exit 0
}

# Keep the query's own failure distinguishable from "the query found nothing"
# (702-68zj). Piping straight into jq collapses both into an empty string, which
# is how the original false all-clear was produced.
if ! raw="$("$PLAN" query --status in_progress --limit 200 --json 2>/dev/null)"; then
    echo "summary: unavailable:plan-query-failed"
    exit 0
fi
if ! rows="$(printf '%s' "$raw" \
    | "$JQ" -r '.[] | [(.order|tostring), (.pickup_role // "unassigned"), .packet_id] | @tsv' 2>/dev/null)"; then
    echo "summary: unavailable:plan-query-unparseable"
    exit 0
fi

total=0
[ -n "$rows" ] && total="$(printf '%s\n' "$rows" | grep -c .)"

# A packet is STRANDED when its most recent recorded activity is the claim
# itself — no progress event since. That is the signature of an interrupted
# cycle: something took it, wrote nothing, and never came back.
#
# ORDER 882-vqe4. COUNT THE FOLDED EVENTS, NOT THE FRAGMENT OVERLAY. This loop
# used to count with `grep -rh "packet_id: <pid>" plan/index.d/*.yaml`, which
# sees a packet's history only until compaction folds it into plan/index.yaml.
# Compaction is routine garbage collection the cycle is told to run, so the
# detector's window was "since the last fold" — and the longer a packet is
# worked, the more likely its evidence has been folded and the more confidently
# this reported it abandoned.
#
# MEASURED on the live ledger 2026-08-25T13:47Z:
#
#   packet     events this loop saw   events that existed
#   865-n8vq            0                    35
#   831-ezea            0                     1
#
# 865-n8vq is a p0 the COORDINATOR had pushed progress into 106 minutes
# earlier. Calling it stranded inverts the whole point of 641-e2qa: the signal
# that exists to surface NEGLECTED work pointed at the work being attended to
# hardest, and diluted the genuine strandings in the same list.
#
# `tillandsias-plan plan-events <pid>` folds base and overlay the way every
# other reader already does. NOTE (992-w7ds): this script no longer CALLS it —
# 946-pdpi moved the classification to `expire-claims` aged output — so the
# paragraph below describes a design, not this script's current behaviour. A second grep against plan/index.yaml would be the
# same defect one storage location later (704-zcgi: the copy has to go, not
# just the instance). When the binary is unavailable the loop DECLINES to
# classify rather than guessing from half the ledger — an unreadable history is
# not an absent one.
# ORDER 946-pdpi. AGE THE CLAIM, DO NOT COUNT ITS EVENTS.
#
# THIS LOOP USED TO ASK THE WRONG QUESTION, and its comment and its code did not
# even agree on which question. The comment said "no progress event SINCE the
# claim"; the code counted `progress|completed|blocked` over the packet's ENTIRE
# history and flagged zero. It read no timestamp, never looked at the claim, and
# never compared the two. "Since" existed only in the prose.
#
# MEASURED on the live ledger 2026-08-31T04:55Z, both error directions in ONE
# run:
#
#   packet     qualifying events   age at claim   old verdict
#   335              5               1 minute     NOT stranded
#   944-jaef         0              35 minutes    STRANDED
#   759-vceg         0               3.2 hours    STRANDED
#
# The FALSE NEGATIVE is the structural one. 335 carries progress events from
# earlier cycles, so it was PERMANENTLY IMMUNE: claimed one minute before the
# run and absent from the report, and it would still be absent if the claiming
# host had died holding it for a week. Every packet that has ever been worked —
# precisely the multi_cycle and repeatedly-claimed set most likely to be claimed
# again — was invisible to this sweep by construction. A sweep structurally
# blind to ever-worked packets is blind to exactly the set most likely to be
# claimed and abandoned, while crying wolf on fresh cycles; both errors came
# from one missing timestamp read.
#
# The FALSE POSITIVE is the noisy one: a cycle that has not yet written a
# progress event is the normal state of its first hour. `expire-claims` agreed
# nothing was past TTL in that same run (expired=0) while this sweep reported
# stranded=4 of population=5 — an 80% rate that measured how many in_progress
# packets had never had a progress event, which correlates with being NEW.
#
# NOT A RE-REPORT OF 882-vqe4, which fixed a different defect in this same loop
# (counting the fragment overlay instead of the folded history). That fix was
# correct and the fold is fine. The predicate on top of it was not.
#
# WHERE THE AGE COMES FROM. `expire-claims --list-live` already derives, per
# in_progress packet, the claim timestamp from the status LWW channel and the
# most recent activity timestamp. Re-deriving either here would be the same
# defect one storage location later (704-zcgi: the copy has to go, not just the
# instance), so this consumes those rows instead of parsing fragments again.
# `--dry-run` is passed with `--list-live` to make the read-only intent explicit
# in the command rather than resting on an observation that it happens not to
# write today.
#
# THRESHOLD, and why it is not the reaper's. The 24h TTL is when a claim becomes
# RECLAIMABLE. This sweep is advisory and exists to warn a human EARLIER, so it
# defaults to 8h and is overridable. Setting it equal to the TTL would make this
# report a duplicate of `threshold_events` below and delete the early warning
# that is the sweep's only reason to exist.
STRANDED_HOURS="${TILLANDSIAS_STRANDED_HOURS:-8}"
case "$STRANDED_HOURS" in
    ''|*[!0-9]*) echo "summary: unavailable:bad-stranded-hours:$STRANDED_HOURS"; exit 2 ;;
esac
[ "$STRANDED_HOURS" -gt 0 ] || { echo "summary: unavailable:bad-stranded-hours:$STRANDED_HOURS"; exit 2 ; }
stranded=0
out=""
if [ -n "$rows" ]; then
    # LET THE BINARY DO THE AGE ARITHMETIC. `expire-claims --ttl-hours N`
    # already answers "which in_progress claims have been idle longer than N
    # hours", against the same status/event history every other reader folds.
    # Two reasons this is not a shortcut:
    #   * 704-zcgi — a second implementation of an existing derivation is the
    #     same defect one storage location later. This sweep asks the question;
    #     it does not get to invent its own arithmetic for it.
    #   * 761-g36m — the shell version of this needed `date -u -d <iso>`, which
    #     is GNU-only, and BSD `date` SUCCEEDS with garbage output, so an
    #     exit-code guard cannot catch it. The gate refused it, correctly. A
    #     portable ISO-to-epoch in POSIX shell is not worth writing when the
    #     binary already has one.
    # `--dry-run` makes the read-only intent explicit rather than resting on
    # an observation that --list-live happens not to write today.
    ec_args="expire-claims --ttl-hours $STRANDED_HOURS --dry-run"
    [ -n "${TILLANDSIAS_STRANDED_NOW_EPOCH:-}" ] \
        && ec_args="$ec_args --now-epoch $TILLANDSIAS_STRANDED_NOW_EPOCH"
    # shellcheck disable=SC2086
    if ! aged="$("$PLAN" $ec_args 2>/dev/null)"; then
        # An unreadable claim table is an UNKNOWN, not a quiet all-clear
        # (702-68zj) — the whole point of the third verdict existing.
        echo "summary: unavailable:expire-claims-failed"
        exit 2
    fi
    while IFS=$'\t' read -r order role pid; do
        [ -n "$pid" ] || continue
        # An `expire-candidate` row means "idle past the threshold we asked
        # about". Report the row's own timestamp rather than a computed age:
        # it is the evidence, it needs no arithmetic, and it does not drift
        # between the run and the reading.
        since="$(printf '%s\n' "$aged" \
            | awk -F'\t' -v p="$pid" '
                $1 == "expire-candidate" && $3 == p {
                    for (i = 4; i <= NF; i++)
                        if ($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) {
                            print $i; exit
                        }
                    print "unknown"; exit
                }')"
        [ -n "$since" ] || continue
        out="${out}stranded	${order}	${role}	${pid}	idle-since=${since}"$'\n'
        stranded=$((stranded + 1))
    done <<< "$rows"
fi

[ -n "$out" ] && printf '%s' "$out"

# ORDER 672-bz7u: when the binary carries expire-claims, threshold_events
# reports how many stranded claims a `tillandsias-plan expire-claims` run
# would return to ready right now (24h TTL). Advisory only — this script
# still closes nothing; the expiry is an explicit, separate invocation.
threshold=0
if "$PLAN" capabilities 2>/dev/null | grep -qx 'expire-claims'; then
    threshold=$("$PLAN" expire-claims --dry-run 2>/dev/null \
        | grep -c '^expire-candidate' || true)
    if [ "${threshold:-0}" -gt 0 ]; then
        # ORDER 1067-24q6: name the WRITE form. Bare `expire-claims` is now a
    # dry-run, so the old hint pointed at a command that would print the
    # candidates again and change nothing — a hint that reads as done.
    echo "hint: ${threshold} claim(s) past the 24h TTL — run 'tillandsias-plan expire-claims --write' to return them to ready (641-e2qa criterion 2)"
    fi
fi
printf 'summary: population=%s in_progress=%s stranded=%s threshold_events=%s\n' \
    "$total" "$total" "$stranded" "${threshold:-0}"
