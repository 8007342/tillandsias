#!/usr/bin/env bash
# test-claim-confirmation-names-the-earliest-claimant.sh — the post-claim step
# must tell the LOSER of a claim race that it lost, and name the winner.
# @trace order:1370-tjme
#
# Hermetic: a one-row scratch ledger, claims written as status-channel
# fragments exactly as `tillandsias-plan set-field` writes them. No network.
#
# PRE-FIX RESULT, pinned as arm 1: the documented check
# `tillandsias-plan next <role> | grep -c <order>` prints 0 for BOTH hosts,
# because any claim hides the row. The row IS listed before any claim, which
# is the premise that makes that 0 mean something.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
[ -n "$PLAN_BIN" ] || { echo "could-not-run:no-plan-binary"; exit 3; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claim-confirm.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

ORDER=9999-zzzz
PID=fixture-claim-race-row
fresh() {
    rm -rf "$W/plan"; mkdir -p "$W/plan/index.d"
    cat > "$W/plan/index.yaml" <<EOF
packets:
  - packet_id: $PID
    order: $ORDER
    status: ready
    kind: defect
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    capability_tags: [plan-ledger]
    estimated_hours: 1
    title: fixture row
    verifiable_closure: fixture
EOF
}
# write_status <file-stamp> <ts> <host> <value>
write_status() {
    cat > "$W/plan/index.d/$1-$3.yaml" <<EOF
status:
  - packet_id: $PID
    field: status
    value: $4
    ts: "$2"
    host: $3
EOF
}
check() { scripts/check-claim-confirmed.sh "$ORDER" --host "$1" --plan-dir "$W/plan"; }
listed() { "$PLAN_BIN" --index "$W/plan/index.yaml" next linux --release v0.5 2>/dev/null | grep -c "$ORDER"; }

# ── arm 1: the pre-fix check cannot tell the two hosts apart ───────────────
fresh
[ "$(listed)" -ge 1 ] && ok "premise: the unclaimed row is listed by next" \
                      || bad "premise: next does not list the unclaimed row, so its 0 would mean nothing"
# A wrote first (19:24:33) but, as on 2026-09-25, B's fragment could land first.
write_status 20260925t192513z 2026-09-25T19:25:13Z hostb in_progress
write_status 20260925t192433z 2026-09-25T19:24:33Z hosta in_progress
[ "$(listed)" = 0 ] && ok "pre-fix: next|grep -c prints 0 once claimed — the same answer for both hosts" \
                    || bad "pre-fix: expected the claimed row hidden from next"

# ── arm 2: the loser is refused and told who won ───────────────────────────
out="$(check hostb)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'refused:claim-lost:9999-zzzz:hostb@2026-09-25T19:25:13Z:earlier=hosta@2026-09-25T19:24:33Z'; then
    ok "the later claimant exits 1 and names the earlier claim"
else bad "later claimant: rc=$rc out=$out"; fi

# ── arm 3: the winner is confirmed ─────────────────────────────────────────
out="$(check hosta)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "ok:claim-confirmed:9999-zzzz:hosta@2026-09-25T19:24:33Z" ] \
    && ok "the earliest claimant exits 0" || bad "earliest claimant: rc=$rc out=$out"

# ── arm 4: a release resets the race; the next claim after it wins ─────────
fresh
write_status 20260925t100000z 2026-09-25T10:00:00Z hosta in_progress
write_status 20260925t110000z 2026-09-25T11:00:00Z hosta ready
write_status 20260925t120000z 2026-09-25T12:00:00Z hostb in_progress
out="$(check hostb)"; rc=$?
[ "$rc" = 0 ] && ok "a claim after a release to ready is confirmed" || bad "after release: rc=$rc out=$out"
out="$(check hosta)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'refused:no-live-claim:9999-zzzz:hosta:held-by=hostb' \
    && ok "the released host holds no live claim" || bad "released host: rc=$rc out=$out"

# ── arm 5: a host that never claimed is refused, not confirmed ─────────────
fresh
out="$(check hosta)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "refused:no-live-claim:9999-zzzz:hosta" ] \
    && ok "no claim is not a confirmation" || bad "no claim: rc=$rc out=$out"

total=$((pass + fail))
if [ "$fail" = 0 ]; then echo "PASS: claim confirmation names the earliest claimant ${pass}/${total} (1370-tjme)"; exit 0; fi
echo "FAIL: claim confirmation ${pass}/${total} (1370-tjme)"; exit 1
