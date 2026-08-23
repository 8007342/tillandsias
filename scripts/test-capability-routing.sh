#!/usr/bin/env bash
# @trace order:847-wgy4, spec:ci-release
#
# Hermetic-by-seams fixture for the capability-aware routing in
# scripts/select-work-batch.sh — every exit criterion of 847-wgy4 as an
# executable case, against the live ledger through the routing seams
# (TILLANDSIAS_CAP_HOSTS / TILLANDSIAS_HOST_TIER / TILLANDSIAS_HOST_ACCELS /
# TILLANDSIAS_ROUTE_ROT / TILLANDSIAS_WORKSTATION).
#
# The 2026-08-19 lesson is the reason for the breadth here: an R4 test passed
# on two hand-picked seeds while the property was false on eleven — "a test
# whose sample could not distinguish the hypothesis from its negation". Case 1
# therefore runs the EIGHT announced identity strings, not two.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
SEL="scripts/select-work-batch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The eight announced fleet identities (from packet 847-wgy4), as a fixture
# roster in the --hosts projection shape: <host>\t<tier>\t<accels>.
ROSTER="$(printf '%s\n' \
    "hilaptop1	gpu-cuda	gpu:amd:unusable,gpu:nvidia:usable" \
    "hilaptop2	cpu	gpu:amd:unusable,npu:amd:usable" \
    "hilaptop3	gpu-rocm	gpu:amd:usable,npu:amd:usable" \
    "lowlap1	cpu	none" \
    "lowlap2	cpu	npu:intel:usable" \
    "macuahuitl	gpu-cuda	gpu:nvidia:usable,npu:intel:unusable" \
    "mstudio	metal	gpu:apple:usable" \
    "oldair	cpu	none" | sort)"

epic_of() { head -1 | sed -n 's/^batch: epic=\([^ ]*\).*/\1/p'; }

# --- case 1 (EC1): eight identities, one day -> pairwise-DISJOINT epics -----
# Every roster host must land on a DIFFERENT epic whenever the frontier has
# room (the live ledger carries more epics than the roster has hosts; the
# case asserts room first so a thinner future frontier weakens the assertion
# loudly instead of silently).
epics=""
hosts_n=8
for h in hilaptop1 hilaptop2 hilaptop3 lowlap1 lowlap2 macuahuitl mstudio oldair; do
    out="$(TILLANDSIAS_CAP_HOSTS="$ROSTER" TILLANDSIAS_WORKSTATION="$h" \
           TILLANDSIAS_HOST_TIER=general TILLANDSIAS_ROUTE_ROT=0 \
           bash "$SEL" linux --seed "fixture-$h")" || fail "case 1: selector refused for $h: $out"
    e="$(printf '%s\n' "$out" | epic_of)"
    [ -n "$e" ] || fail "case 1: no epic in header for $h: $(printf '%s\n' "$out" | head -1)"
    printf '%s\n' "$out" | head -1 | grep -q "route=rank:" \
        || fail "case 1: $h did not route by rank: $(printf '%s\n' "$out" | head -1)"
    epics="${epics}${e}"$'\n'
done
distinct="$(printf '%s' "$epics" | sort -u | grep -c .)"
width="$(TILLANDSIAS_CAP_HOSTS="$ROSTER" TILLANDSIAS_WORKSTATION=macuahuitl \
    TILLANDSIAS_HOST_TIER=general TILLANDSIAS_ROUTE_ROT=0 bash "$SEL" linux \
    | head -1 | sed -n 's/.*width=\([0-9]*\).*/\1/p')"
if [ "${width:-0}" -ge "$hosts_n" ]; then
    [ "$distinct" -eq "$hosts_n" ] \
        || fail "case 1: $hosts_n hosts with frontier room (width=$width) landed on only $distinct distinct epics:"$'\n'"$epics"
else
    [ "$distinct" -eq "${width:-0}" ] \
        || fail "case 1: width=$width but only $distinct distinct epics"
fi
echo "ok: case 1 — eight identities, eight disjoint epics (width=$width)"

# --- case 2 (EC2): the accel filter can exclude, and only subtracts ---------
none_triage="$(TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general \
    TILLANDSIAS_HOST_ACCELS= bash "$SEL" linux | grep '^triage:')"
all_triage="$(TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general \
    TILLANDSIAS_HOST_ACCELS="cuda rocm npu metal" bash "$SEL" linux | grep '^triage:')"
none_filtered="$(printf '%s' "$none_triage" | sed -n 's/.*accel_filtered=\([0-9]*\).*/\1/p')"
printf '%s' "$all_triage" | grep -q 'accel_filtered=' \
    && fail "case 2: a fully-accelerated host must subtract nothing: $all_triage"
[ "${none_filtered:-0}" -gt 0 ] \
    || fail "case 2: NEGATIVE CONTROL — an accel-less host subtracted nothing; the filter cannot exclude ($none_triage)"
none_eligible="$(printf '%s' "$none_triage" | sed -n 's/.*eligible=\([0-9]*\).*/\1/p')"
all_eligible="$(printf '%s' "$all_triage" | sed -n 's/.*eligible=\([0-9]*\).*/\1/p')"
[ $((none_eligible + none_filtered)) -eq "$all_eligible" ] \
    || fail "case 2: subtraction does not account: $none_eligible + $none_filtered != $all_eligible"
echo "ok: case 2 — accel filter excludes ($none_filtered live carriers) and accounts exactly"

# --- case 3 (EC3): anti-starvation — rotation walks every frontier slot -----
# One host, rotations 0..width-1: the picks must cover `width` DISTINCT
# epics (the rotation reaches every slot), and width must be >= the old K=3
# (nothing reachable yesterday is unreachable today).
[ "${width:-0}" -ge 3 ] || fail "case 3: width=$width < 3 — reachability narrowed"
walk=""
rot=0
while [ "$rot" -lt "$width" ]; do
    e="$(TILLANDSIAS_CAP_HOSTS="$ROSTER" TILLANDSIAS_WORKSTATION=macuahuitl \
        TILLANDSIAS_HOST_TIER=general TILLANDSIAS_ROUTE_ROT="$rot" \
        bash "$SEL" linux | epic_of)"
    walk="${walk}${e}"$'\n'
    rot=$((rot + 1))
done
walked="$(printf '%s' "$walk" | sort -u | grep -c .)"
[ "$walked" -eq "$width" ] \
    || fail "case 3: rotation over $width days visited only $walked distinct epics — a frontier slot is starved:"$'\n'"$walk"
echo "ok: case 3 — one host walks all $width frontier slots across rotations"

# --- case 4 (EC4): no roster row -> byte-identical to the seeded pick -------
# Two runs with routing structurally unavailable (empty roster, accel seam
# unset, general tier) must be deterministic AND carry no routing artifacts.
run_a="$(TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general bash "$SEL" linux --seed fixture-ec4)"
run_b="$(TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general bash "$SEL" linux --seed fixture-ec4)"
[ "$run_a" = "$run_b" ] || fail "case 4: rowless runs are not deterministic"
printf '%s\n' "$run_a" | head -1 | grep -q 'route=' \
    && fail "case 4: a rowless host must not carry a route field: $(printf '%s\n' "$run_a" | head -1)"
printf '%s\n' "$run_a" | head -1 | grep -qE 'pick=[0-9]+/3' \
    || fail "case 4: a rowless host must keep the K=3 seeded pick: $(printf '%s\n' "$run_a" | head -1)"
echo "ok: case 4 — rowless host degrades to the seeded top-3 pick, no routing artifacts"

# --- case 5 (mandate): low-end tier gets ONLY tier work, loudly -------------
out="$(TILLANDSIAS_HOST_TIER=low-end TILLANDSIAS_CAP_HOSTS= bash "$SEL" linux)" \
    || fail "case 5: low-end selection refused while tier work exists: $out"
printf '%s\n' "$out" | head -1 | grep -q 'route=tier:low-end' \
    || fail "case 5: low-end batch not marked route=tier:low-end: $(printf '%s\n' "$out" | head -1)"
# The refusal half: a tier with no claimable work must REFUSE, never fall
# back to the general queue. Driven through the TILLANDSIAS_TIER_TAGS seam
# with a tag no packet carries — the earlier form asked for role macos and
# broke the day the ledger gained role-any low-end work (861-n7f5): a
# refusal case must not depend on what the live ledger happens to lack.
out2="$(TILLANDSIAS_HOST_TIER=low-end TILLANDSIAS_CAP_HOSTS= \
    TILLANDSIAS_TIER_TAGS=fixture-tier-tag-no-packet-carries bash "$SEL" linux)"
rc2=$?
[ "$rc2" -ne 0 ] || fail "case 5: an empty tier must refuse, got: $(printf '%s\n' "$out2" | head -1)"
printf '%s' "$out2" | grep -q '^refused:no-tier-work:' \
    || fail "case 5: expected refused:no-tier-work, got: $out2"
echo "ok: case 5 — low-end host gets tier work only, and refuses rather than draining generally"

echo "PASS: capability routing (5/5)"
