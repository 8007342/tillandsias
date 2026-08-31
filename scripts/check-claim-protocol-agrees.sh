#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:943-unii, order:814-iyu7
#
# ORDER 943-unii. Refuse a tree in which the WORKER skill and the COORDINATOR
# skill specify different claim mechanisms.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-30/31. Three sources described
# claiming, and one disagreed:
#
#   * skills/meta-orchestration/SKILL.md (coordinator):
#       claim = `set-field <order> status in_progress`, pushed BEFORE the work.
#   * methodology/distributed-work.yaml:
#       "a claim event changes status from ready to in_progress" — agrees.
#   * skills/advance-work-from-plan/SKILL.md §3 (worker):
#       claim = `append-event <id> claim`, pushed WITH the work.
#
# `append-event` changes no status. `plan_next` / `plan_ready` /
# `select-work-batch.sh` filter to `unleased`, and "leased" means exactly
# `status: in_progress`, so the worker recipe claimed nothing. Packet 245
# carried 43 claim events and stayed in the `ready` pool; `expire-claims`
# reported `in_progress=0` fleet-wide; on 2026-08-18 two hosts implemented
# 798-tk7b six minutes apart, ~4h duplicated (814-iyu7). The outlier was the
# one document every worker host executes every cycle.
#
# WHY A CROSS-DOCUMENT CHECK AND NOT A LINT. Each file was internally coherent
# and reviewed fine on its own; nothing in the tree ever read the two together.
# The divergence was invisible precisely because it lived BETWEEN files, so the
# check has to be the comparison itself.
#
# WHAT IT COMPARES. The `tillandsias-plan set-field … status in_progress`
# recipe from each skill, normalised to its command SHAPE — placeholders,
# quoting, and line continuations collapsed — so that rewording a `--reason`
# string is free but changing the mechanism is not.
#
# Verdict grammar, one line on stdout:
#   ok:claim-protocol-agrees:<shape>            exit 0
#   violation:claim-protocol:<reason>           exit 1
#   blocked:<reason>                            exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

WORKER="${TILLANDSIAS_WORKER_SKILL:-skills/advance-work-from-plan/SKILL.md}"
COORD="${TILLANDSIAS_COORD_SKILL:-skills/meta-orchestration/SKILL.md}"

for f in "$WORKER" "$COORD"; do
    [ -f "$f" ] || { echo "blocked:skill-missing:$f"; exit 2; }
done

# Reduce a file's claim recipe to a command shape.
#   - join backslash continuations
#   - keep only the `tillandsias-plan set-field ... status in_progress ...` line
#   - replace every <placeholder>, "$(...)", $var and "quoted string" with ARG
#   - collapse whitespace
claim_shape() {
    sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$1" \
    | grep -E 'tillandsias-plan[[:space:]]+set-field.*status[[:space:]]+in_progress' \
    | sed -E \
        -e 's/"\$\([^)]*\)"/ARG/g' \
        -e 's/\$\([^)]*\)/ARG/g' \
        -e 's/<[^>]*>/ARG/g' \
        -e 's/"[^"]*"/ARG/g' \
        -e "s/'[^']*'/ARG/g" \
        -e 's/\$[A-Za-z_][A-Za-z0-9_]*/ARG/g' \
        -e 's/^[[:space:]]*//; s/[[:space:]]+$//' \
        -e 's/[[:space:]]+/ /g' \
    | head -1
}

worker_shape="$(claim_shape "$WORKER")"
coord_shape="$(claim_shape "$COORD")"

[ -n "$coord_shape" ] || { echo "violation:claim-protocol:coordinator-has-no-set-field-claim-recipe"; exit 1; }
[ -n "$worker_shape" ] || { echo "violation:claim-protocol:worker-has-no-set-field-claim-recipe"; exit 1; }

if [ "$worker_shape" != "$coord_shape" ]; then
    echo "violation:claim-protocol:shapes-differ"
    echo "  worker($WORKER):      $worker_shape" >&2
    echo "  coordinator($COORD):  $coord_shape" >&2
    exit 1
fi

# The mechanism agreeing is not enough: the worker must also state the two
# rules that make claiming SAFE. Both were absent while the divergence stood.
grep -qiE 'BEFORE the work' "$WORKER" \
    || { echo "violation:claim-protocol:worker-omits-push-claim-before-work"; exit 1; }
grep -qE 'set-field[^\n]*status[[:space:]]+ready' "$WORKER" \
    || { echo "violation:claim-protocol:worker-omits-release-on-exit-recipe"; exit 1; }

echo "ok:claim-protocol-agrees:${worker_shape}"
