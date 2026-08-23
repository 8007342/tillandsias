#!/usr/bin/env bash
# @trace order:662-s9z5, spec:ci-release
#
# Hermetic fixture for scripts/reclaim-stranded-claims.sh after its 662-s9z5
# rewrite (delegate to expire-claims; typed refusals; apply-with-nothing-
# reclaimed exits non-zero). The original defect was a sweep that reported
# candidates=7 reclaimed=0 mode=apply as a SUCCESS line for a whole session —
# so the cases here pin both directions: a genuinely stale claim IS reclaimed,
# and a fresh one is refused BY NAME with a typed reason and a non-zero apply.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || fail "no runnable tillandsias-plan"
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

NOW=1787443200  # 2026-08-23T00:00:00Z
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

scaffold() {
    # <dir> <claim_ts>: a tree with one in_progress packet claimed at claim_ts.
    local dir="$1" claim_ts="$2"
    mkdir -p "$dir/scripts" "$dir/plan/index.d"
    cp "$ROOT/scripts/reclaim-stranded-claims.sh" \
       "$ROOT/scripts/check-stranded-in-progress.sh" \
       "$ROOT/scripts/plan-binary-probe.sh" "$dir/scripts/"
    cat > "$dir/plan/index.yaml" <<LEDGER
packets:
  - packet_id: fix-claimed
    order: 901-aaaa
    title: "f"
    status: in_progress
    desired_release: v0.5
    pickup_role: linux
    events:
      - type: note
        ts: "${claim_ts}"
        host: fixturehost
        summary: claimed for cycle ${claim_ts}
LEDGER
}

run() { ( cd "$1" && shift && TILLANDSIAS_PLAN_BIN="$PLAN" bash scripts/reclaim-stranded-claims.sh "$@" ); }

# --- case 1: a claim 48h old is reclaimed by --apply ------------------------
d="$WORK/stale"; scaffold "$d" "2026-08-21T00:00:00Z"
out="$(run "$d" --now "$NOW")" || fail "case 1: dry-run must exit 0, got: $out"
printf '%s\n' "$out" | grep -q '^reclaim	901-aaaa	fix-claimed	' \
    || fail "case 1: stale claim not listed for reclaim: $out"
out="$(run "$d" --apply --now "$NOW")" || fail "case 1: apply that reclaims must exit 0, got: $out"
printf '%s\n' "$out" | grep -q 'summary: candidates=1 reclaimed=1 refused=0 mode=apply' \
    || fail "case 1: wrong apply summary: $out"
status="$(cd "$d" && "$PLAN" status 901-aaaa | cut -f2)"
[ "$status" = "ready" ] || fail "case 1: packet not returned to ready, status=$status"
echo "ok: case 1 — a 48h-old claim is reclaimed and the packet is ready again"

# --- case 2 (NEGATIVE CONTROL): a fresh claim is refused, typed, non-zero ---
d="$WORK/fresh"; scaffold "$d" "2026-08-22T23:00:00Z"   # 1h before NOW
out="$(run "$d" --now "$NOW")" || fail "case 2: dry-run with refusals must exit 0, got: $out"
printf '%s\n' "$out" | grep -q '^refused	901-aaaa	fix-claimed	within-ttl$' \
    || fail "case 2: fresh claim not refused by name: $out"
out="$(run "$d" --apply --now "$NOW")"
rc=$?
[ "$rc" -eq 1 ] || fail "case 2: apply that reclaims NOTHING must exit 1, got rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'summary: candidates=1 reclaimed=0 refused=1 mode=apply' \
    || fail "case 2: wrong no-op summary: $out"
echo "ok: case 2 — a fresh claim is declined by name and the no-op apply is non-zero"

# --- case 3: nothing stranded is a clean zero -------------------------------
d="$WORK/none"; scaffold "$d" "2026-08-21T00:00:00Z"
( cd "$d" && TILLANDSIAS_PLAN_BIN="$PLAN" "$PLAN" set-field 901-aaaa status ready --host fixturehost --reason "fixture reset" >/dev/null )
out="$(run "$d" --apply --now "$NOW")" || fail "case 3: empty sweep must exit 0, got: $out"
printf '%s\n' "$out" | grep -q 'summary: candidates=0 reclaimed=0 refused=0 mode=apply' \
    || fail "case 3: wrong empty summary: $out"
echo "ok: case 3 — an empty stranded set is a clean zero, not an error"

echo "PASS: reclaim stranded claims (3/3)"
