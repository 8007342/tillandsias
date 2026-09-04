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
    # No --seed here: since 949-uv5k an explicit --seed is the documented
    # OVERRIDE that routes by seed instead of rank, and the selector then prints
    # no `route=` field at all. This case asserts RANK routing by identity;
    # determinism comes from TILLANDSIAS_ROUTE_ROT=0 and the identity itself.
    # (The case passed `--seed fixture-$h` from before that fix and read
    # "did not route by rank" on every host once the override became real.)
    out="$(TILLANDSIAS_CAP_HOSTS="$ROSTER" TILLANDSIAS_WORKSTATION="$h" \
           TILLANDSIAS_HOST_TIER=general TILLANDSIAS_ROUTE_ROT=0 \
           bash "$SEL" linux)" || fail "case 1: selector refused for $h: $out"
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
# The positive half asserts that a low-end host WITH tier work gets routed to
# it. That depends on the live ledger still carrying a ready `low-end` packet
# claimable by role linux — and on 2026-09-04 it did not, so this half had gone
# RED on trunk while `./build.sh --check` stayed green (the gate does not run
# this fixture). Note the refusal half below already learned this lesson after
# 861-n7f5 and was rewritten to drive a seam instead; the positive half was
# left depending on what the ledger happens to HAVE, which is the same
# fragility pointed the other way.
# So: probe first, and when there is no tier work to route, say the half did
# not run rather than failing (or, worse, passing vacuously) — 965-sxec, a
# check that could not run never claims what it would have found.
out="$(TILLANDSIAS_HOST_TIER=low-end TILLANDSIAS_CAP_HOSTS= bash "$SEL" linux)"
rc_lowend=$?
if [ "$rc_lowend" -eq 0 ]; then
    printf '%s\n' "$out" | head -1 | grep -q 'route=tier:low-end' \
        || fail "case 5: low-end batch not marked route=tier:low-end: $(printf '%s\n' "$out" | head -1)"
    _case5_positive="routed"
elif printf '%s' "$out" | grep -q '^refused:no-tier-work:'; then
    # No ready low-end work in the ledger right now. That is a fact about the
    # pool, not a routing regression, and the refusal itself is what the second
    # half asserts on purpose.
    _case5_positive="NOT RUN (ledger carries no ready low-end work for role linux)"
else
    fail "case 5: low-end selection failed for a reason other than an empty tier: $out"
fi
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
echo "ok: case 5 — low-end routing: positive half ${_case5_positive}; refuses rather than draining generally"


# --- case 6 (1002-7jeg): present-but-unusable hardware gets the BRING-UP lane
# The defect this pins: HOST_ACCELS was built from `:usable` states alone, so a
# packet whose deliverable is "make device X schedulable" was hidden from the
# host whose X was present but not yet usable — the only host that could lift
# it. Measured 2026-09-04: no host in the fleet reported a usable NPU, so all
# five ready npu packets were unselectable by EVERYONE, permanently.
#
# Both directions are driven through the seams, so no real accelerator host is
# needed. The two states must diverge:
#   present-but-unusable -> offered  (accel_bringup names the tag)
#   absent entirely      -> withheld (accel_filtered names the tag)
bringup_triage() { printf '%s\n' "$1" | grep -m1 '^triage:'; }

out_present="$(TILLANDSIAS_HOST_ACCELS= TILLANDSIAS_HOST_ACCELS_PRESENT=npu \
    TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general bash "$SEL" linux --seed fixture-bringup)"
out_absent="$(TILLANDSIAS_HOST_ACCELS= TILLANDSIAS_HOST_ACCELS_PRESENT= \
    TILLANDSIAS_CAP_HOSTS= TILLANDSIAS_HOST_TIER=general bash "$SEL" linux --seed fixture-bringup)"

bringup_triage "$out_present" | grep -q 'accel_bringup=[^ ]*npu' \
    || fail "case 6: hardware present-but-unusable must enter the bring-up lane, got: $(bringup_triage "$out_present")"
bringup_triage "$out_absent" | grep -q 'accel_bringup=' \
    && fail "case 6: a host with NO such device must NOT get the bring-up lane: $(bringup_triage "$out_absent")"

# The substantive half — the present host must actually see MORE work — can
# only be asserted when the ledger carries npu-tagged ready work. Rather than
# passing vacuously when it does not, say so (965-sxec: a check that could not
# run never claims what it would have found).
npu_ready="$(bringup_triage "$out_absent" | grep -o 'accel_filtered=[0-9]*(\([^)]*\))' | grep -c 'npu' || true)"
if [ "$npu_ready" -gt 0 ]; then
    e_present="$(bringup_triage "$out_present" | grep -o 'eligible=[0-9]*' | cut -d= -f2)"
    e_absent="$(bringup_triage "$out_absent"  | grep -o 'eligible=[0-9]*' | cut -d= -f2)"
    [ "$e_present" -gt "$e_absent" ] \
        || fail "case 6: bring-up host saw eligible=$e_present, not more than the absent host's $e_absent — the lane is not reaching the pool"
    echo "ok: case 6 — present-but-unusable enters the bring-up lane (eligible $e_absent -> $e_present); absent stays withheld"
else
    echo "ok: case 6 — bring-up lane opens and closes correctly (count half NOT RUN: ledger carries no ready npu work)"
fi

# --- case 7 (1002-7jeg): the subtraction NAMES what it dropped ---------------
# A bare `accel_filtered=N` cannot distinguish a correct subtraction from a
# permanently starved device class, which is why the npu starvation survived
# unnoticed. The count must carry the tags that produced it.
if [ "$npu_ready" -gt 0 ]; then
    bringup_triage "$out_absent" | grep -qE 'accel_filtered=[0-9]+\([a-z]+:[0-9]+' \
        || fail "case 7: accel_filtered must name the tags it dropped, got: $(bringup_triage "$out_absent")"
    echo "ok: case 7 — accel_filtered names what it filtered, not just how many"
else
    echo "ok: case 7 — naming format NOT RUN (nothing was filtered to name)"
fi


# --- case 8 (1011-d578): where a host is POINTED is pool-independent ---------
# EC1 (case 1) counts distinct epics, and whether it discriminates depends on
# what the live ledger happens to hold — it passed on a broken selector hours
# before it caught one. This case tests the PROPERTY instead, so it has teeth
# regardless of the pool.
#
# Ordinal routing promises that distinct ranks give disjoint epics. That holds
# only if every host's ordinal indexes the SAME list. Before 1011-d578 the list
# was the host's OWN post-subtraction pool, so slot k named different epics on
# different hosts and disjointness was emergent rather than guaranteed.
#
# The invariant, stated directly: hold rank and rotation fixed, vary ONLY the
# host's own capabilities, and the epic it is pointed at must not move. Its own
# pool still decides what it WORKS; it must not decide where it is POINTED.
#
# MUTATION CONTROL, measured 2026-09-04: against the pre-fix selector this case
# FAILS — macuahuitl routes to harness-mcp-expert-validation with
# `gpu:nvidia:usable` and to convergence-velocity-milestone once
# `npu:intel:unusable` is added, purely because the extra tag widened its own
# pool. Same rank, same rot, same ledger, different destination.
mk_probe_roster() {
    printf '%s\n' \
        "hilaptop1	gpu-cuda	gpu:amd:unusable,gpu:nvidia:usable" \
        "hilaptop2	cpu	gpu:amd:unusable,npu:amd:usable" \
        "hilaptop3	gpu-rocm	gpu:amd:usable,npu:amd:usable" \
        "lowlap1	cpu	none" \
        "lowlap2	cpu	npu:intel:usable" \
        "macuahuitl	gpu-cuda	$1" \
        "mstudio	metal	gpu:apple:usable" \
        "oldair	cpu	none" | sort
}
probe_epic=""
for accels in "gpu:nvidia:usable" \
              "gpu:nvidia:usable,npu:intel:unusable" \
              "gpu:nvidia:usable,npu:intel:usable" \
              "none"; do
    e="$(TILLANDSIAS_CAP_HOSTS="$(mk_probe_roster "$accels")" \
         TILLANDSIAS_WORKSTATION=macuahuitl TILLANDSIAS_HOST_TIER=general \
         TILLANDSIAS_ROUTE_ROT=0 bash "$SEL" linux | epic_of)"
    [ -n "$e" ] || fail "case 8: no epic routing with accels=$accels"
    if [ -z "$probe_epic" ]; then
        probe_epic="$e"
    elif [ "$e" != "$probe_epic" ]; then
        fail "case 8: the host's OWN capabilities moved where it is pointed — accels='$accels' routed to $e, but $probe_epic with the first set. The ordinal is indexing this host's filtered pool instead of the shared routing frontier (1011-d578)."
    fi
done
echo "ok: case 8 — where a host is pointed is pool-independent (4 capability sets, all -> $probe_epic)"

echo "PASS: capability routing (8/8)"
