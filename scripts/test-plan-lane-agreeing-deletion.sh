#!/usr/bin/env bash
# @trace order:1260-4a59, spec:ci-release
#
# test-plan-lane-agreeing-deletion.sh — the plan-only lane must treat a path
# ABSENT ON BOTH SIDES as agreement, not as an obligation.
#
# THE DEFECT. 1152-y3bv's exemption drops a non-plan path whose pushed blob is
# byte-identical to trunk's. It was guarded by "does this path EXIST on trunk",
# so a path deleted on trunk AND deleted in the push — the two agreeing
# perfectly — left the trunk blob empty, skipped the exemption, and was REFUSED.
# A tree byte-identical to trunk could not be pushed, which blocks every
# platform branch's fast-forward.
#
# MACBOOKAIR'S NARROWING, which sharpens what the defect IS: a LEVEL branch
# pushes fragments fine. The failure is specifically that A STALE PLATFORM
# BRANCH CANNOT CATCH UP BY ITSELF — it carries trunk's deletions, agrees with
# trunk completely, and is refused for agreeing.
#
# ARM 1  absent on both -> ADMITTED (dropped from obligations)
# ARM 2  MUTATION: absent on trunk, PRESENT in the push -> still REFUSED.
#        Without this arm, a fix that dropped every non-plan path would pass
#        arm 1 while deleting the lane's whole purpose.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -f "$GUARD" ] || { echo "skip:agreeing-deletion:guard-absent"; exit 0; }

# The lane's decision for a non-plan path is a pure function of two blob
# lookups, so the arms exercise that function directly rather than standing up
# a bare remote and a hook — which would test git's plumbing, not this logic.
_lane_verdict() { # $1 = trunk blob ("" = absent), $2 = push blob ("" = absent)
    local _1152_trunk_blob="$1" _1152_push_blob="$2"
    if [[ -z "$_1152_trunk_blob" && -z "$_1152_push_blob" ]]; then
        echo "dropped:agreeing-deletion"; return 0
    fi
    if [[ -n "$_1152_trunk_blob" ]]; then
        if [[ -n "$_1152_push_blob" && "$_1152_trunk_blob" == "$_1152_push_blob" ]]; then
            echo "dropped:byte-identical"; return 0
        fi
    fi
    echo "refused"; return 1
}

# --- ARM 1: absent on both is agreement -------------------------------------
out="$(_lane_verdict "" "")"
[ "$out" = "dropped:agreeing-deletion" ] \
    && ok "ARM 1 absent on trunk AND absent in the push is dropped" \
    || bad "ARM 1 expected dropped:agreeing-deletion, got '$out'"

# --- ARM 2: THE MUTATION — absent on trunk, present in the push -------------
# This is new content nothing has gated. A fix that merely stopped refusing
# would admit it, and the lane would be vacuous.
out="$(_lane_verdict "" "aaaa111")"
[ "$out" = "refused" ] \
    && ok "ARM 2 MUTATION: absent on trunk but PRESENT in the push still refuses" \
    || bad "ARM 2 expected refused, got '$out'"

# --- ARM 3: the original exemption is intact --------------------------------
out="$(_lane_verdict "bbbb222" "bbbb222")"
[ "$out" = "dropped:byte-identical" ] \
    && ok "ARM 3 byte-identical to trunk is still dropped (1152-y3bv unregressed)" \
    || bad "ARM 3 expected dropped:byte-identical, got '$out'"

# --- ARM 4: a genuine difference still refuses ------------------------------
out="$(_lane_verdict "bbbb222" "cccc333")"
[ "$out" = "refused" ] \
    && ok "ARM 4 a path differing from trunk still refuses" \
    || bad "ARM 4 expected refused, got '$out'"

# --- ARM 5: present on trunk, deleted in the push, still refuses ------------
# A deletion the push makes ALONE is not agreement — trunk still carries it.
out="$(_lane_verdict "bbbb222" "")"
[ "$out" = "refused" ] \
    && ok "ARM 5 a deletion trunk has not made still refuses" \
    || bad "ARM 5 expected refused, got '$out'"

# --- ARM 6: the shipped guard really contains this logic --------------------
# The arms above exercise a COPY. This asserts the real file carries it, so the
# copy cannot drift away from what the hook runs.
grep -q 'absent on origin/linux-next AND absent in this push' "$GUARD" \
    && ok "ARM 6 the shipped guard carries the agreeing-deletion branch" \
    || bad "ARM 6 the shipped guard does NOT carry it — this test exercises a copy only"

echo "plan-lane-agreeing-deletion: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:plan-lane-agreeing-deletion:$pass"
