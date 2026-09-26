#!/usr/bin/env bash
# check-claim-confirmed.sh — after claiming an order, did THIS host win it?
# @trace order:1370-tjme
# @trace order:1140-d6ni (claims are by order, through the plan lane)
#
# THE DEFECT THIS REPLACES. join-the-fleet §3 and advance-work-from-plan
# confirmed a claim with `tillandsias-plan next <role> | grep -c <order>` → 0.
# ANY host's claim hides the row from `next`, so the LOSER of a claim race
# reads 0 exactly as the winner does. Measured 2026-09-25 on 776-jcf3:
# lenovinha wrote its claim at 19:24:33Z and pushed at 19:28:42Z; yoga wrote at
# 19:25:13Z and pushed first. Both read "confirmed". The coordinator then ruled
# by PUSH order, which is also wrong: a claim can sit unpushed for minutes.
#
# THE RULE. Read the row's status-field WRITES (the LWW `status:` channel that
# `set-field` appends to plan/index.d/), ordered by their own `ts`. The claims
# that count are the `in_progress` writes after the row's last non-in_progress
# status (a release to ready, a completion, a block). The EARLIEST of those
# holds the order. Push time and commit time are never consulted.
#
# LIMIT, stated: the history is read from the fragment overlay. `compact` folds
# fragments into the base and keeps only the current value, so a race older
# than the last compaction cannot be re-judged here. A race is judged in the
# minutes after a claim; run this after `git pull`, before implementing.
#
# USAGE: scripts/check-claim-confirmed.sh <order> --host <host> [--plan-dir DIR]
# OUTPUT (one line on stdout):
#   ok:claim-confirmed:<order>:<host>@<ts>                              exit 0
#   refused:claim-lost:<order>:<host>@<ts>:earlier=<host>@<ts>:<file>   exit 1
#   refused:no-live-claim:<order>:<host>[:held-by=<host>@<ts>]          exit 1
#   could-not-run:<reason>                                              exit 3
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

order=""; host=""; plan_dir="$ROOT/plan"
while [ $# -gt 0 ]; do
    case "$1" in
        --host) host="${2:-}"; shift 2 ;;
        --plan-dir) plan_dir="${2:-}"; shift 2 ;;
        -*) echo "could-not-run:unknown-argument:$1"; exit 3 ;;
        *) order="$1"; shift ;;
    esac
done
if [ -z "$order" ] || [ -z "$host" ]; then
    echo "could-not-run:usage: check-claim-confirmed.sh <order> --host <host> [--plan-dir DIR]"
    exit 3
fi
command -v jq >/dev/null 2>&1 || { echo "could-not-run:no-jq"; exit 3; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
[ -n "$PLAN_BIN" ] || { echo "could-not-run:no-plan-binary"; exit 3; }

# order -> packet_id, through the fold (the status row's third column).
status_line="$("$PLAN_BIN" --index "$plan_dir/index.yaml" status "$order" 2>/dev/null)"
pid="$(printf '%s\n' "$status_line" | awk -F'\t' -v o="$order" '$1 == o { print $3; exit }')"
[ -n "$pid" ] || { echo "could-not-run:unresolved-order:$order"; exit 3; }

# Every status-field write for this packet in the overlay: ts \t host \t value \t file.
writes="$(
    for f in "$plan_dir"/index.d/*.yaml; do
        [ -f "$f" ] || continue
        grep -qF -- "$pid" "$f" || continue
        "$PLAN_BIN" yaml-json "$f" 2>/dev/null \
          | jq -r --arg p "$pid" --arg f "$(basename "$f")" '
              (.status // [])[]
              | select(.packet_id == $p and .field == "status")
              | [.ts, (.host // ""), .value, $f] | @tsv'
    done | sort -t$'\t' -k1,1 -k4,4
)"

# Claims after the last non-claim status write.
live="$(printf '%s\n' "$writes" | awk -F'\t' '
    NF < 3 { next }
    $3 != "in_progress" { n = 0; next }
    { rows[++n] = $0 }
    END { for (i = 1; i <= n; i++) print rows[i] }')"

first="$(printf '%s\n' "$live" | sed -n '1p')"
mine="$(printf '%s\n' "$live" | awk -F'\t' -v h="$host" '$2 == h { print; exit }')"

if [ -z "$mine" ]; then
    if [ -n "$first" ]; then
        echo "refused:no-live-claim:$order:$host:held-by=$(printf '%s' "$first" | cut -f2)@$(printf '%s' "$first" | cut -f1)"
    else
        echo "refused:no-live-claim:$order:$host"
    fi
    exit 1
fi
mine_ts="$(printf '%s' "$mine" | cut -f1)"
if [ "$(printf '%s' "$first" | cut -f2)" = "$host" ]; then
    echo "ok:claim-confirmed:$order:$host@$mine_ts"
    exit 0
fi
echo "refused:claim-lost:$order:$host@$mine_ts:earlier=$(printf '%s' "$first" | cut -f2)@$(printf '%s' "$first" | cut -f1):$(printf '%s' "$first" | cut -f4)"
exit 1
