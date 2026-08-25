#!/usr/bin/env bash
# @trace order:874-w2gc
#
# sweep-salvage-refs.sh — the CONSUMER the salvage net was missing.
#
# ORDER 874-w2gc. 872-c9nd/874-s8vf made pushing a dirty tree to
# refs/heads/salvage/* work; nothing then LOOKED at those refs. A salvaged
# tree nobody ever notices is prose-with-extra-steps — the rescue happened,
# the recovery never will. This sweep is the coordinator-cycle step that turns
# a salvage ref into a ledger event, so rescued work is visible in the plan
# and claimable like any other row.
#
# What it does, in order:
#   1. `git ls-remote <remote> 'refs/heads/salvage/*'` — the ground truth.
#   2. For each ref, checks whether the ref path is already NAMED anywhere in
#      the ledger (plan/index.yaml + plan/index.d/*.yaml). Compaction folds
#      fragments into the base preserving event text, so this survives folds.
#   3. With --apply, appends one progress event per UNSEEN ref to the salvage
#      packet (the-salvage-net-had-never-caught-anything-and-could-not,
#      874-s8vf's row) through tillandsias-plan — which means the write goes
#      through the 874-idnt identity validation like every other ledger write.
#      Without --apply it only reports (report mode never writes anything).
#   4. Reports the local overlap-refusals.jsonl (873-zcim exit criterion 3's
#      durable record, which also had no consumer): total refusals, how many
#      are new since the last consumed cursor, and the newest line. --apply
#      advances the cursor. Refusals are host-local telemetry — they are
#      REPORTED for the coordinator to judge, not written to the ledger.
#
# RETENTION DECISION (exit criterion 3, recorded here and on the ledger row):
# salvage refs are kept until a human or coordinator confirms the rescued
# content is merged or consciously abandoned; deletion then requires
# TILLANDSIAS_SALVAGE_DELETE_OK=1 past the pre-push guard. No automatic
# time-based reaping: the refs are tiny, the work they carry was by
# definition unrecoverable from anywhere else, and an expiry policy would
# reintroduce exactly the silent-loss failure the net exists to end.
#
# Verdict grammar (last stdout line):
#   ok:salvage-sweep:refs=<total>:new=<unseen>:filed=<events-written>:refusals-new=<n>
#   fail:salvage-sweep:<reason>
#
# Seams (fixture use): TILLANDSIAS_SALVAGE_REMOTE (default origin),
# TILLANDSIAS_SWEEP_PLAN_BIN (default target/debug/tillandsias-plan, PATH
# fallback), TILLANDSIAS_CYCLE_STATE_DIR (shared with cycle-checkout-lock.sh).
set -uo pipefail

ROOT="${TILLANDSIAS_SALVAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "fail:salvage-sweep:no-root"; exit 2; }

REMOTE="${TILLANDSIAS_SALVAGE_REMOTE:-origin}"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"
REFUSALS="$STATE_DIR/overlap-refusals.jsonl"
CURSOR="$STATE_DIR/overlap-refusals.cursor"
PACKET="the-salvage-net-had-never-caught-anything-and-could-not"

# Resolve through the canonical probe (704-zcgi/751-vega): a hardcoded
# target/ path selects the wrong architecture on shared WSL checkouts.
PLAN_BIN="${TILLANDSIAS_SWEEP_PLAN_BIN:-}"
if [ -z "$PLAN_BIN" ] && [ -f "$ROOT/scripts/plan-binary-probe.sh" ]; then
    # shellcheck source=scripts/plan-binary-probe.sh
    . "$ROOT/scripts/plan-binary-probe.sh"
    PLAN_BIN="$(resolve_plan_binary || true)"
fi
if [ -z "$PLAN_BIN" ]; then
    echo "fail:salvage-sweep:no-plan-binary"
    exit 1
fi

apply=0
[ "${1:-}" = "--apply" ] && apply=1

# ── 1. ground truth ──────────────────────────────────────────────────────────
if ! ls_out="$(git ls-remote "$REMOTE" 'refs/heads/salvage/*' 2>&1)"; then
    echo "fail:salvage-sweep:ls-remote:$(printf '%s' "$ls_out" | head -1 | cut -c1-80)"
    exit 1
fi

total=0 new=0 filed=0
new_refs=()
while IFS=$'\t' read -r sha ref; do
    [ -n "${ref:-}" ] || continue
    total=$((total + 1))
    # 2. seen = the ref path is named anywhere in the folded or unfolded ledger.
    if grep -rqF "$ref" plan/index.yaml plan/index.d/ 2>/dev/null; then
        continue
    fi
    new=$((new + 1))
    new_refs+=("$ref $sha")
    echo "unseen: $ref $sha"
done <<EOF
$ls_out
EOF

# ── 3. file unseen refs as ledger events (apply mode only) ───────────────────
if [ "$apply" -eq 1 ] && [ "$new" -gt 0 ]; then
    agent="${TILLANDSIAS_AGENT_ID:-$("$ROOT/scripts/agent-identity.sh" id salvage-sweep 2>/dev/null)}"
    host="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
    [ -n "$host" ] || host="unknown"
    for entry in "${new_refs[@]}"; do
        ref="${entry% *}"; sha="${entry##* }"
        summary="SALVAGED WORK AWAITING RECOVERY: $ref ($sha) is on the remote and not yet merged or consciously abandoned. Filed by scripts/sweep-salvage-refs.sh (874-w2gc). Inspect: git fetch $REMOTE $ref && git diff HEAD FETCH_HEAD --stat. When recovered or dismissed, say so in a follow-up event; deletion needs TILLANDSIAS_SALVAGE_DELETE_OK=1."
        if "$PLAN_BIN" append-event "$PACKET" progress --agent "$agent" --host "$host" --summary "$summary" >/dev/null 2>&1; then
            filed=$((filed + 1))
            echo "filed: $ref"
        else
            echo "fail:salvage-sweep:append-event:$ref"
            exit 1
        fi
    done
fi

# ── 4. overlap-refusals consumer (873-zcim residue) ──────────────────────────
ref_total=0
if [ -f "$REFUSALS" ]; then
    ref_total="$(wc -l < "$REFUSALS" | tr -d ' ')"
fi
consumed=0
if [ -f "$CURSOR" ]; then
    consumed="$(cat "$CURSOR" 2>/dev/null | tr -cd '0-9')"
    [ -n "$consumed" ] || consumed=0
fi
# A truncated/rotated file must not make the delta negative.
[ "$consumed" -gt "$ref_total" ] && consumed=0
ref_new=$((ref_total - consumed))
if [ "$ref_new" -gt 0 ]; then
    echo "overlap-refusals: $ref_new new since last sweep; newest:"
    tail -1 "$REFUSALS"
fi
if [ "$apply" -eq 1 ] && [ "$ref_new" -gt 0 ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$ref_total" > "$CURSOR" 2>/dev/null || true
fi

echo "ok:salvage-sweep:refs=$total:new=$new:filed=$filed:refusals-new=$ref_new"
