#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-pickup-role-grammar.sh — report how far `pickup_role` has drifted from a
# token into free prose, and how many packets that drift misroutes.
#
# Order 632-retq companion (Windows host, 2026-08-09). Evidence feed for the
# p0 packet `query-and-next-disagree-on-role-eligibility` (632-39p3).
#
# THE TWO HALVES OF ONE DEFECT
# ----------------------------
# `pickup_role` is consumed by two matchers that disagree, and each fails in the
# opposite direction:
#
#   crates/.../lib.rs   `pr == r || pr == "any"`     exact  -> UNDER-matches
#   crates/.../main.rs  case-insensitive substring          -> OVER-matches
#
# 632-39p3 records the under-match half (`any` dropped by `query --role`, which
# starved the Windows and macOS lanes). This script measures the OVER-match half,
# which is the more dangerous of the two because it is silent in the other
# direction: instead of hiding work, it hands a host work that belongs to a
# different lane.
#
# Worked example from the live ledger, 2026-08-09:
#
#   packet 513 dev-end-user-gating-litmus
#   pickup_role: "linux (litmus harness); Windows/macOS replicate later"
#
# `query --status ready --role windows` returns it, because "Windows" appears in
# the prose. The packet is owned by linux, its harness is linux, and the clause
# that mentions Windows says explicitly that Windows comes LATER. A greedy
# Windows cycle draining its queue claims linux's p0 work and blocks on a forge
# it cannot launch.
#
# WHY A SEPARATE CHECKER AND NOT A MATCHER FIX
# --------------------------------------------
# Which semantics `query --role` should have is an open decision owned by
# 632-39p3 ("both are defensible; having both simultaneously is not"), and that
# packet's own notes warn that drain-queue and the `plan_query` MCP tool both
# consume it. Changing the matcher from another host, mid-decision, would be
# drift. Measuring the damage is a reduction step that does not preempt it.
#
# NO jq, NO yq, NO python, NO ruby — grep/sed/awk only. Deliberate: the sibling
# script scripts/select-work-batch.sh cannot run on Windows AT ALL because it
# needs jq, which is the residual filed as packet 632-retq. A checker meant to
# report on cross-host routing that only runs on one host would be self-defeating.
#
# CO-OWNED IS NOT MISROUTED
# -------------------------
# Naming two lanes is not automatically a defect. "linux (XDNA2 lane) + macos
# (Metal lane)" means both hosts genuinely own a half, and the substring matcher
# offering it to both is the RIGHT answer by accident. Counting those as damage
# would inflate the number and train readers to ignore it.
#
# The unambiguous mis-routes are the SEQUENCED forms — a value naming a second
# lane only to say that lane comes later, verifies afterwards, or merely
# supports: "…; Windows/macOS replicate later", "…with linux control-wire
# support". There the second role is explicitly NOT the owner, and handing the
# packet to it is always wrong. So the verdict counts those separately and only
# they set a non-zero exit.
#
# GRAMMAR — exactly one verdict line on stdout:
#   ^pickup-role: total=N canonical=N prose=N multi_host=N sequenced=N verdict=(ok:canonical-roles|attention:sequenced-prose)$
# With --detail, one line per multi-lane value BEFORE the verdict line:
#   ^(sequenced|co-owned)\t<pickup_role value>\towner=<role>\tclaimable-as=<role,role>$
# Exit 0 when sequenced=0, 1 otherwise.

set -uo pipefail

DETAIL=0
[ "${1:-}" = "--detail" ] && DETAIL=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# The canonical token set. `any` is a wildcard rather than a host and is treated
# as canonical but never as an owner or a mis-route target.
CANON='linux|macos|windows|any|forge|linux_mutable|linux_immutable|coordinator|tlatoani'
# Only these name a concrete host lane, so only these can be mis-claimed.
HOSTS='linux macos windows'

# TILLANDSIAS_PICKUP_ROLE_INPUT names a file of raw pickup_role values, one per
# line, used INSTEAD of scanning the ledger. It exists so the litmus can assert
# the classifier against fixtures with known answers, including a negative
# control. Asserting against the live ledger only would make the test restate
# whatever the ledger currently happens to contain — it would pass on a ledger
# where every value is prose, as long as the script agreed with itself.
if [ -n "${TILLANDSIAS_PICKUP_ROLE_INPUT:-}" ]; then
    if [ ! -f "$TILLANDSIAS_PICKUP_ROLE_INPUT" ]; then
        echo "pickup-role: refused:no-such-input:${TILLANDSIAS_PICKUP_ROLE_INPUT}"
        exit 2
    fi
    values="$(grep -v '^ *$' "$TILLANDSIAS_PICKUP_ROLE_INPUT")"
else
    # READ THE FOLDED LEDGER, NOT THE RAW TEXT.
    #
    # This script's first version grepped `pickup_role:` out of plan/index.yaml
    # plus plan/index.d/*.yaml. That is the pre-fold text, and it is the wrong
    # population: a correction sent through the LWW channel (a `status:` entry
    # with `field: pickup_role`) changes what every READER sees while leaving the
    # base line it overrides untouched on disk. So the grep kept reporting values
    # that no consumer had seen for hours.
    #
    # Caught immediately, and in the most direct way available: this cycle
    # normalized three pickup_role values through that channel, confirmed via
    # `tillandsias-plan query` that the folded values had changed and that the
    # Windows claimable queue had dropped from 7 to 6 — and this checker still
    # reported all three as offenders.
    #
    # Which makes it an instance of the exact defect it was written to report:
    # active, internally consistent, and measuring a population the system does
    # not use. Reading the fold is not an optimization here, it is the only way
    # the number means anything.
    PLAN=""
    for c in ./target/release/tillandsias-plan ./target/debug/tillandsias-plan \
             ./target/release/tillandsias-plan.exe ./target/debug/tillandsias-plan.exe \
             "$(command -v tillandsias-plan 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { PLAN="$c"; break; }
    done
    if [ -z "$PLAN" ]; then
        # Refuse rather than fall back to the raw grep. A fallback that silently
        # measures a different population is precisely what this script exists to
        # catch, and it would report a stale number as a current one.
        echo "pickup-role: refused:no-plan-binary:cannot read the folded ledger (build with cargo build --release -p tillandsias-plan)"
        exit 2
    fi

    # Only pickup_role is extracted, so splitting records on `},{` is safe: the
    # field is a short role string with no braces or escaped quotes. No jq — see
    # the portability note above.
    values="$("$PLAN" query --limit 0 --json 2>/dev/null \
        | sed 's/},{/}\n{/g' \
        | sed -n 's/.*"pickup_role":"\([^"]*\)".*/\1/p' \
        | grep -v '^ *$')"

    if [ -z "$values" ]; then
        echo "pickup-role: refused:empty-projection:the plan binary returned no pickup_role values"
        exit 2
    fi
fi

if [ -z "$values" ]; then
    # An empty set is NOT a clean ledger. A checker that reports "no problems
    # found" when it in fact found nothing to inspect converts every future
    # breakage of its input into a passing run — the same silent-misclassification
    # class this script reports on.
    echo "pickup-role: refused:empty-projection:no pickup_role values to inspect"
    exit 2
fi

total="$(printf '%s\n' "$values" | grep -c .)"
canonical="$(printf '%s\n' "$values" | grep -cEi "^($CANON)$")"
prose=$((total - canonical))

multi_host=0
sequenced=0
detail_out=""

# Words that demote a named lane from owner to follower. If one of these appears
# anywhere in a multi-lane value, the extra lanes are not co-owners.
SEQ_WORDS='later|verif|replicate|support|afterward|follow|then'

# A value is MISROUTED when it names more than one concrete host lane: the first
# such token is the owner, and every later one is a role the substring matcher
# will hand this packet to. Single-host prose ("macOS host (needs a live Darwin
# probe)") is untidy but routes correctly, so it is not counted here — this
# number is damage, not style.
# BUILTINS, NOT SPAWNS (order 661-2wsz sibling, windows host 2026-08-10).
#
# This loop originally ran `printf | grep` several times per value: a canonical
# check, one presence test per host, then position and claim passes. Across 626
# values that is well over a thousand processes, and on Windows the checker took
# **100,128 ms** — blowing this litmus's own 60s step timeout the moment the test
# was bound and actually executed.
#
# The irony is worth recording: this is the same one-spawn-per-item pattern I had
# just fixed in scripts/freshness-inventory.sh an hour earlier (126.8s -> 4.7s).
# I fixed it in someone else's script and shipped it in my own, because until
# this test was bound nothing ever ran it and the cost was invisible.
#
# `shopt -s nocasematch` makes `[[ ]]` case-insensitive, so every one of those
# tests becomes a shell builtin with no process at all. The only remaining spawn
# is one `tr` per MULTI-LANE value — 4 of 626 — where a byte position is needed.
# Available on bash 3.2 (macOS), which this script must run on.
shopt -s nocasematch

while IFS= read -r v; do
    [ -n "$v" ] || continue
    [[ "$v" =~ ^($CANON)$ ]] && continue

    owner=""
    extra=""
    for h in $HOSTS; do
        if [[ "$v" == *"$h"* ]]; then
            if [ -z "$owner" ]; then
                # Earliest-appearing host token is the declared owner.
                owner="$h"
            else
                extra="${extra:+$extra,}$h"
            fi
        fi
    done

    # Re-derive the owner by position, not by $HOSTS iteration order.
    if [ -n "$extra" ]; then
        # One lowercase copy so prefix-stripping can find the byte offset
        # case-insensitively; ${v,,} is bash 4+ and macOS ships 3.2.
        lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
        first_pos=999999
        for h in $HOSTS; do
            case "$lower" in
                *"$h"*)
                    prefix="${lower%%"$h"*}"
                    p="${#prefix}"
                    if [ "$p" -lt "$first_pos" ]; then first_pos="$p"; owner="$h"; fi
                    ;;
            esac
        done
        claim=""
        for h in $HOSTS; do
            [ "$h" = "$owner" ] && continue
            [[ "$v" == *"$h"* ]] && claim="${claim:+$claim,}$h"
        done
        multi_host=$((multi_host + 1))
        if [[ "$v" =~ ($SEQ_WORDS) ]]; then
            sequenced=$((sequenced + 1))
            kind="sequenced"
        else
            kind="co-owned"
        fi
        detail_out="${detail_out}${kind}	${v}	owner=${owner}	claimable-as=${claim}
"
    fi
done <<EOF
$values
EOF

if [ "$DETAIL" -eq 1 ] && [ -n "$detail_out" ]; then
    printf '%s' "$detail_out"
fi

if [ "$sequenced" -eq 0 ]; then
    echo "pickup-role: total=$total canonical=$canonical prose=$prose multi_host=$multi_host sequenced=0 verdict=ok:canonical-roles"
    exit 0
fi

echo "pickup-role: total=$total canonical=$canonical prose=$prose multi_host=$multi_host sequenced=$sequenced verdict=attention:sequenced-prose"
exit 1
