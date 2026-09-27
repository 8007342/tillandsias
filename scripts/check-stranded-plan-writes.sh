#!/usr/bin/env bash
# @trace order:1232-av4p, spec:ci-release
#
# check-stranded-plan-writes.sh — name the PACKETS whose status only a salvage or
# work ref knows about.
#
# salvage-audit.sh (1226-jb8y) answers which FILES on salvage/* and work/* refs
# are not on trunk, and which side is ahead. On 2026-09-26 that was 351 lines
# across 50 refs. The dangerous subset is invisible in a file list: a
# `status:` write on a ref for a packet trunk reads differently. That is how an
# unreachable forge session closed EIGHT packets onto a salvage ref while trunk
# kept offering them as ready (1232-av4p), and how 1430-9227 found 18
# never-landed fragments, one of which would have flipped 437 wrongly.
#
# This reads the audit's RELAY CANDIDATES only (ref-may-be-AHEAD / ABSENT —
# never a stale snapshot the branch has moved past), takes each plan fragment's
# status writes from the REF's copy, and names every packet whose ref value
# differs from trunk's folded status. It decides nothing: a line here is a
# question for the coordinator (relay, refuse, or re-verify), not an action.
#
# A ref value that merely DIFFERS from trunk is not yet a finding: an old claim
# for a packet trunk has since completed loses to trunk's later write under LWW,
# and relaying it would change nothing. So each fragment is folded INTO A
# SCRATCH COPY OF TRUNK'S LEDGER with the real plan binary — no second
# implementation of the LWW/ladder rules to drift — and a line says
# `would-change` only when that fold's status differs from trunk's.
#
# GRAMMAR
#   stranded:would-change:<order>:<packet_id>:ref=<value>:trunk=<status>:folded=<status>:<fragment>:refs=<r1,..>
#   stranded:superseded:<order>:<packet_id>:ref=<value>:trunk=<status>:<fragment>:refs=<r1,..>
#   ok:stranded-plan-writes:<n> would-change, <s> superseded, on <m> ref(s)   exit 0
#   could-not-run:stranded-plan-writes:<reason>                  exit 3
#
# --from <file> reads a saved salvage-audit transcript instead of running it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
REMOTE="origin"
FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        *) echo "could-not-run:stranded-plan-writes:unknown-argument:$1"; exit 3 ;;
    esac
done
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
[ -n "$PLAN_BIN" ] || { echo "could-not-run:stranded-plan-writes:no-plan-binary"; exit 3; }

if [ -n "$FROM" ]; then
    audit="$(cat "$FROM" 2>/dev/null)" || { echo "could-not-run:stranded-plan-writes:unreadable:$FROM"; exit 3; }
else
    audit="$(bash "$ROOT/scripts/salvage-audit.sh" 2>&1)"
fi
case "$(tail -n 1 <<<"$audit")" in
    ok:salvage-audit:*) ;;
    skipped:salvage-audit:*) echo "ok:stranded-plan-writes:0 packet(s) on 0 ref(s)"; exit 0 ;;
    *) echo "could-not-run:stranded-plan-writes:salvage-audit-failed"; exit 3 ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/stranded-plan-writes.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# (ref, fragment) pairs the audit calls relay candidates.
awk '
    /^  [^ ]/ { ref = $1; next }
    /^    plan\/index\.d\/[^ ]+\.yaml/ && ($2 == "ref-may-be-AHEAD" || $2 == "ABSENT") { print ref "\t" $1 }
' <<<"$audit" > "$work/pairs"

# ref value per (fragment, packet); refs joined when one fragment sits on many.
: > "$work/writes"
while IFS=$'\t' read -r ref frag; do
    [ -n "$ref" ] && [ -n "$frag" ] || continue
    git show "$REMOTE/$ref:$frag" > "$work/frag.yaml" 2>/dev/null || continue
    "$PLAN_BIN" yaml-json "$work/frag.yaml" > "$work/frag.json" 2>/dev/null || continue
    # The plan binary's own reader, not jq (1375-tsfu ratchet: trunk moves jq
    # call sites to `tillandsias-plan json get`). Its subset has no @tsv, add,
    # join or string building, so it emits one compact ["id","value"] per
    # write and awk adds the columns; ids and status values are plain tokens.
    if ! "$PLAN_BIN" json get -c \
            '((.status // [])[], (.fields // [])[]) | select(.field == "status" and (.packet_id // "") != "") | [.packet_id, (.value | tostring)]' \
            "$work/frag.json" > "$work/pairs.json" 2>/dev/null; then
        echo "could-not-run:stranded-plan-writes:json-get-refused:$frag"; exit 3
    fi
    awk -F'"' -v frag="$frag" -v ref="$ref" 'NF >= 5 { print $2 "\t" $4 "\t" frag "\t" ref }' \
        "$work/pairs.json" >> "$work/writes"
done < "$work/pairs"

# Trunk's ledger, once, into a scratch tree the fragments are folded into.
mkdir -p "$work/trunk"
git archive "$REMOTE/linux-next" plan/index.yaml plan/index.d 2>/dev/null | tar -x -C "$work/trunk" 2>/dev/null \
    || { echo "could-not-run:stranded-plan-writes:cannot-extract-trunk-ledger"; exit 3; }
TIDX="$work/trunk/plan/index.yaml"

n=0; sup=0; refs_seen=""
sort -u "$work/writes" | awk -F'\t' '{ k = $1 "\t" $2 "\t" $3; r[k] = (k in r) ? r[k] "," $4 : $4; ref1[k] = (k in ref1) ? ref1[k] : $4 } END { for (k in r) print k "\t" r[k] "\t" ref1[k] }' \
    | sort > "$work/grouped"
while IFS=$'\t' read -r pid value frag refs ref1; do
    line="$("$PLAN_BIN" --index "$TIDX" status "$pid" 2>/dev/null | head -n 1)"
    order="$(cut -f1 <<<"$line")"; trunk="$(cut -f2 <<<"$line")"
    [ -n "$trunk" ] || { order="?"; trunk="absent-on-trunk"; }
    [ "$trunk" = "$value" ] && continue
    dest="$work/trunk/$frag"
    if [ -e "$dest" ]; then folded="$trunk"
    else
        git show "$REMOTE/$ref1:$frag" > "$dest" 2>/dev/null
        folded="$("$PLAN_BIN" --index "$TIDX" status "$pid" 2>/dev/null | head -n 1 | cut -f2)"
        rm -f "$dest"
        [ -n "$folded" ] || folded="$trunk"
    fi
    if [ "$folded" != "$trunk" ]; then
        echo "stranded:would-change:$order:$pid:ref=$value:trunk=$trunk:folded=$folded:$frag:refs=$refs"
        n=$((n + 1))
    else
        echo "stranded:superseded:$order:$pid:ref=$value:trunk=$trunk:$frag:refs=$refs"
        sup=$((sup + 1))
    fi
    refs_seen="$refs_seen,$refs"
done < "$work/grouped"
m="$(tr ',' '\n' <<<"$refs_seen" | grep -v '^$' | sort -u | grep -c .)"
echo "ok:stranded-plan-writes:$n would-change, $sup superseded, on $m ref(s)"
exit 0
