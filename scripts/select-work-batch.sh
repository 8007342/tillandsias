#!/usr/bin/env bash
# @trace spec:ci-release
#
# select-work-batch.sh — choose ONE cohesive, budgeted batch of plan packets for
# a single orchestration cycle.
#
# Order 626-* (operator directive 2026-08-09).
#
# THE PROBLEM THIS SOLVES
# -----------------------
# `tillandsias-plan next <role>` already answers "what is claimable?" correctly:
# release-aware, role-compatible, dependency-clear, unleased, priority-ranked.
# What it does not answer is "what should ONE cycle take?", and that is where
# the cost was going:
#
#   * NO COHESION. The top 5 for `linux` routinely span five unrelated themes
#     (worker skills, loop status, git-mirror identity, …). An agent draining
#     them context-switches five times and re-reads five subsystems, so a cycle
#     that closes one small packet can burn more tokens in orientation than in
#     work.
#   * NO PREDICTABLE SIZE. Every cycle takes whatever it takes. Consecutive
#     `/meta-orchestration` calls on different agents and harnesses drain wildly
#     different amounts, so throughput cannot be reasoned about.
#   * NO ANTI-CIRCLING. A packet can accumulate progress events forever without
#     changing status, and nothing notices it is being re-picked and re-explored.
#
# THE ABSTRACTION ALREADY EXISTED
# -------------------------------
# The tier between "release" and "packet" is NOT new and must not be reinvented:
# it is `release_target: <milestone-packet-id>`, already carried by 171 packets
# across 7 milestones, already preferred by worker selection
# (methodology/distributed-work.yaml). Milestones ARE the epics.
#
# The reason it did not feel like a layer is coverage: on 2026-08-09 only 60 of
# 176 ready v0.5 packets carried one. Two thirds of the work was ungrouped, so
# selection fell back to flat priority order, which is exactly the scatter above.
# This script makes the existing tier load-bearing and makes the gap VISIBLE
# instead of silently degrading into scatter.
#
# USAGE
#   scripts/select-work-batch.sh <role> [--budget N] [--release V]
#
# GRAMMAR — a batch header, then one line per packet, then a triage line:
#   ^batch: epic=<id|UNGROUPED> role=<r> release=<v> size=<n> budget=<n>
#            score=<f> seed=<s> pick=<i>/<k>[ urgent=<packet_id>][ harness=<packet_id>]$
#          `urgent=` appears ONLY when the order-645 override displaced a slot
#          with a strictly-higher-priority packet from outside the chosen epic.
#          `harness=` appears ONLY when the order-555 forge harness-affinity
#          pick took the batch head (TILLANDSIAS_HOST_KIND=forge with
#          TILLANDSIAS_AGENT set and a matching [harness-validation, <agent>]
#          packet ready).
#   ^packet\t<order>\t<packet_id>\t<priority>$
#   ^triage: eligible=<n> grouped=<n> ungrouped=<n> epics=<n> urgency_unscored=<n>[ caps_filtered=<n>]$
#          `caps_filtered=` appears ONLY when host-capability filtering dropped
#          rows (see HOST TOOL CAPABILITIES below).
# or exactly one refusal line:
#   ^refused:(no-eligible-work|no-plan-binary|missing-tool|stale-plan-binary|query-failed|bad-role|no-tier-work):.*$
# Exit 0 on a batch, 1 on refusal.
#
# "NO WORK" MUST MEAN NO WORK (order 631-*, Windows host 2026-08-09)
# -----------------------------------------------------------------
# Every jq call below is a hard dependency, and jq is NOT installed on the
# Windows host (`plan/issues/litmus-corpus-not-host-aware-windows-2026-08-03.md`
# already records it missing there alongside yq and ruby). With `2>/dev/null` on
# the flatten, an absent jq made `rows` empty and the script reported
# `refused:no-eligible-work` — indistinguishable from a genuinely drained
# ledger. A greedy `/meta-orchestration` loop on that host reads the refusal,
# concludes the plan is empty, and idles for hours while ready packets for its
# own role sit claimable (7 of them at the time this was found).
#
# That is the precise failure class this repo calls a silent misclassification:
# an environment fault wearing the costume of a legitimate terminal state. The
# two preflights below make the fault its own refusal token, so the caller can
# branch on it instead of believing it.
#
# MINIMAX, NOT SHINY (methodology/convergence.yaml -> minimax_convergence_strategy)
# --------------------------------------------------------------------------
# Ranking epics by priority alone implements the exact anti-pattern that file
# names: "raising average convergence by improving low-risk obligations while a
# high-risk maximum residual remains unresolved." p0 is a claim about urgency,
# not about residual, and the p0-first agent will keep finding p0s.
#
# So the epic score follows that file's selection rule — maximum residual first,
# tie-broken by downstream dependency count — approximated with data actually in
# the ledger:
#
#   urgency   best (lowest) priority rank in the epic       — still counts
#   blocking  how many OTHER packets depend on this epic's  — "downstream
#             packets, i.e. the residual it is holding up      dependency count"
#   neglect   how old the epic's oldest ready packet is,    — anti-starvation
#             by order token (tokens are ~chronological)
#
# ENTROPY, AND WHY IT DOES NOT BREAK PREDICTABILITY
# -------------------------------------------------
# A purely deterministic argmax starves everything that is never top-ranked, and
# makes two concurrent hosts pick the SAME epic and collide. So the top-K epics
# form a candidate set and the seed picks within it.
#
# The seed is explicit and printed. That is the whole trick: the run is
# REPRODUCIBLE (same seed + same ledger -> same batch, so a cycle can be
# replayed and audited) while the SEQUENCE spreads coverage over time and across
# hosts. Predictable drain is a property of batch SIZE, which the budget fixes
# absolutely; it was never a property of always choosing the same work.
# Default seed = host IDENTITY + UTC date, so one host varies day to day and
# two hosts on the same day diverge.
#
# IT USED TO BE HOST *KIND* + DATE, and that is not an identity: `linux_mutable`
# or the bare fallback `host` is shared by every box of that kind, so all five
# Silverblue laptops in the fleet derived a byte-identical seed on any given day
# and picked the same epic. The documented workaround was "pass --seed", which
# is an invariant that depends on nine operators remembering a flag.
# scripts/derive-host-identity.sh replaces it with
# <osgroup>-<cpu>-<accel>-<hostname>, unique by hostname and readable in a
# roster. Operator directive, 2026-08-22.
#
# THE SEED ALONE DOES NOT SEPARATE HOSTS — the ROSTER does (order 847-wgy4).
# A host with a published capability row is routed by its ORDINAL RANK in the
# shared `capability-matrix --hosts` roster, rotated daily, over a frontier
# widened to the roster size: distinct hosts hold distinct ranks, so any two
# row-holding hosts get DISJOINT epics whenever the frontier has room — which
# no hash or seed can promise (8 hashed hosts over 11 epics expect ~2.5
# birthday collisions; ordinals expect zero). The seeded top-K pick below
# remains the path for hosts with NO row, where R1 claiming keeps their
# collisions merely wasteful rather than duplicated. Separation therefore
# GROWS as 850-bif2 rows land, host by host, with no flag to remember.
#
# KNOWN TRADEOFF of the date-based default: every cycle on one host that day
# picks the SAME epic until its packets drain. That is mostly a FEATURE — it
# gives cohesion ACROSS cycles, not just within one, so an epic gets driven
# toward done instead of being hopped between. The cost is that a day seeded
# onto a low-residual epic spends the day there. Squared weighting holds that
# at roughly 1 day in 10; pass --seed explicitly to override when it happens.
# Do not "fix" this by reseeding per cycle without replacing the cross-cycle
# cohesion it provides.

set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROLE="${1:-}"
shift 2>/dev/null || true
BUDGET=""
RELEASE=""
SEED=""
TOPK="3"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --budget)  BUDGET="${2:-}"; shift 2 ;;
        --budget=*) BUDGET="${1#--budget=}"; shift ;;
        --release) RELEASE="${2:-}"; shift 2 ;;
        --release=*) RELEASE="${1#--release=}"; shift ;;
        --seed)    SEED="${2:-}"; shift 2 ;;
        --seed=*)  SEED="${1#--seed=}"; shift ;;
        --topk)    TOPK="${2:-}"; shift 2 ;;
        --topk=*)  TOPK="${1#--topk=}"; shift ;;
        *) echo "refused:bad-role:unknown argument $1"; exit 1 ;;
    esac
done

case "$ROLE" in
    linux|macos|windows|any) ;;
    *) echo "refused:bad-role:${ROLE:-<empty>} (want linux|macos|windows|any)"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# ARGUMENTS BEFORE ENVIRONMENT. A caller error must not be reported as an
# environment fault: with the probes first, `--budget 0` on a host without jq
# refused with `missing-tool`, so the same bad invocation produced different
# diagnoses on different hosts and the litmus's bad-budget control passed only
# where jq happened to be installed.
# DEFAULT BUDGET. Order 707-3x9d & Order 682-yiz7 (2026-08-12):
# - Litmus-launched forge runs (TILLANDSIAS_LITMUS_STEP) take at most ONE packet
#   to strictly respect the 600s unattended step budget (order 264).
# - Autonomous / pairing forge cycles scale to an adaptive budget (default 4,
#   or TILLANDSIAS_CYCLE_BUDGET) to maximize the work-to-orchestration ratio.
# - Non-forge hosts scale default 6 -> 10 per 682-yiz7 evidence-backed tuning.
if [ -z "$BUDGET" ]; then
    if [ -n "${TILLANDSIAS_CYCLE_BUDGET:-}" ]; then
        BUDGET="$TILLANDSIAS_CYCLE_BUDGET"
    elif [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        if [ -n "${TILLANDSIAS_LITMUS_STEP:-}" ]; then
            BUDGET=1
        else
            BUDGET=4
        fi
    else
        BUDGET=10
    fi
fi
case "$BUDGET" in ''|*[!0-9]*) echo "refused:bad-role:budget must be a positive integer"; exit 1 ;; esac
[ "$BUDGET" -ge 1 ] || { echo "refused:bad-role:budget must be >= 1"; exit 1; }

# TILLANDSIAS_PLAN_BIN overrides the probe so the litmus can point this script at
# a stub that fails the way a stale binary fails. Without it the stale-binary and
# query-failed refusals are untestable on exactly the hosts CI runs on — the ones
# whose binary is current — which is how the hole they close survived in the first
# place.
# Order 704-zcgi: one shared probe, because this script's own copy of the
# `[ -x ... ]` first-match probe refused on a Windows host whose `.exe` was
# sitting right there — the third script to write that same bug. An executable
# BIT is a claim; RUNNING the binary is evidence.
#
# TILLANDSIAS_PLAN_BIN still overrides (the shared probe tries it first), so the
# litmus can point this script at a stub that fails the way a stale binary
# fails. Without it the stale-binary and query-failed refusals are untestable on
# exactly the hosts CI runs on — the ones whose binary is current — which is how
# the hole they close survived in the first place.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || {
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
        echo "refused:no-plan-binary:TILLANDSIAS_PLAN_BIN=${TILLANDSIAS_PLAN_BIN} did not run"
    else
        echo "refused:no-plan-binary:build with cargo build --release -p tillandsias-plan"
    fi
    exit 1
}

# ORDER 632-retq (rung 2). The jq preflight that stood here is gone WITH the jq
# calls it guarded. Every projection below now comes from `tillandsias-plan
# select-rows` / `blocking-counts`, which do the filtering and ranking inside the
# binary that already owns the folded ledger.
#
# The preflight was correct for its time: it made an absent jq a loud
# `refused:missing-tool` instead of a counterfeit "drained ledger". But it left
# the host still unable to select work, and satisfying the dependency per host
# repeats the yq/ruby exposure recorded 2026-08-03. Removing the dependency
# deletes the class. TILLANDSIAS_JQ is still read by the litmus to prove the
# selector no longer cares.


# ${arr[@]+"${arr[@]}"} guards the expansions below: under set -u, bash < 4.4
# (stock macOS ships 3.2) treats "${arr[@]}" on an empty array as an unbound
# variable — and REL_ARG is empty on every skill-driven call (no --release).
# Same argv-guard shape as build-image.sh NO_CACHE_ARGS.
# DEFAULT TO THE ACTIVE RELEASE. Without --release, `query` returns every
# release, and the selector was ranking v0.5, v0.6 and v0.7 work against each
# other — then printing whichever release the first row happened to carry, which
# read like a filter that was never applied. On 2026-08-09 that surfaced as
# `release=v0.7` in a header while the active release was v0.5.
#
# Selecting v0.7 work while v0.5 is the active bundle is precisely the
# "agents work obsolete/not-yet-relevant packets" failure this selector exists to
# prevent. `tillandsias-plan next` already defaults from the folded ACTIVE
# RELEASE heading; match it. --release still overrides for deliberate cross-release
# passes.
if [ -z "$RELEASE" ]; then
    RELEASE="$("$PLAN" next "$ROLE" --limit 1 2>/dev/null \
        | grep -o "in desired_release '[^']*'" | head -1 \
        | sed "s/.*'\(.*\)'/\1/")"
fi
REL_ARG=()
[ -n "$RELEASE" ] && REL_ARG=(--release "$RELEASE")

if [ -z "$SEED" ]; then
    # The identity probe is read-only, needs no build, and degrades to `unknown`
    # components rather than guessing. If it is missing or fails outright, fall
    # back to the old kind+date shape rather than refusing — a work selector
    # that cannot run because a naming helper is absent would be a worse
    # failure than a colliding seed, and the fallback is exactly the behaviour
    # that shipped before.
    _identity=""
    if [ -x "$(dirname "$0")/derive-host-identity.sh" ]; then
        _identity="$("$(dirname "$0")/derive-host-identity.sh" 2>/dev/null || true)"
    fi
    if [ -n "$_identity" ]; then
        SEED="${_identity}-$(date -u +%Y%m%d)"
    else
        SEED="$(hostname -s 2>/dev/null || echo host)-$(date -u +%Y%m%d)"
        echo "note: derive-host-identity.sh unavailable — seeding by hostname, which COLLIDES across same-named hosts" >&2
    fi
fi

# ── CAPABILITY-AWARE ROUTING INPUTS (order 847-wgy4) ─────────────────────────
# The seed cannot separate hosts (see THIS ALONE DOES NOT SEPARATE HOSTS
# above); the capability matrix can. `capability-matrix --hosts` is a sorted,
# deterministic roster of every host with a published row — identical on every
# host at the same ledger state — so a host's ORDINAL POSITION in it is a
# collision-free routing key: distinct hosts get distinct ranks by
# construction, which is stronger than any hash and needs no coordination.
#
# Seams: TILLANDSIAS_CAP_HOSTS (set-even-empty) injects a fixture roster;
# TILLANDSIAS_HOST_TIER overrides the local core probe;
# TILLANDSIAS_HOST_ACCELS (set-even-empty) overrides the accel set;
# TILLANDSIAS_WORKSTATION names this host (agent-identity precedence).
# The comment above says "agent-identity precedence" and this block used to
# implement a private, weaker approximation of it: `hostname -s || hostname`,
# which resolves empty in every Fedora image, none of which ship a `hostname`
# binary. An empty HOST_NAME here does not fail loudly — it just never matches
# a row in the capability matrix, so a forge silently routes as an unknown host
# (order 859-b2zc). Call the shared helper instead of describing it.
# shellcheck source=scripts/agent-identity.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-identity.sh"
HOST_NAME="$(tillandsias_lower "$(tillandsias_agent_workstation)")"

if [ -n "${TILLANDSIAS_CAP_HOSTS+x}" ]; then
    CAP_HOSTS="$TILLANDSIAS_CAP_HOSTS"
else
    # A matrix the binary cannot serve is an ABSENT roster, never a fatal
    # fault: routing degrades to the seeded pick (exit criterion 4).
    CAP_HOSTS="$("$PLAN" capability-matrix --hosts 2>/dev/null || true)"
fi
MY_CAP_LINE=""
[ -n "$HOST_NAME" ] && MY_CAP_LINE="$(printf '%s\n' "$CAP_HOSTS" | awk -F'\t' -v h="$HOST_NAME" '$1==h' | head -1)"

# THE LOW-END TIER (operator mandate 2026-08-16/23, stated in the skill's
# fleet section): machines with roughly four physical cores are the fleet's
# deliberate LOWER BOUND and take profiling/characterization work in their own
# tier, NEVER the general queue — a slow host in the general queue produces
# slow duplicates of work a faster host already claimed. The probe is local
# (the selector runs on the host it selects for), so the mandate holds even
# for a host with no capability row.
if [ -n "${TILLANDSIAS_HOST_TIER:-}" ]; then
    HOST_TIER="$TILLANDSIAS_HOST_TIER"
else
    _phys=""
    if [ -r /proc/cpuinfo ]; then
        _phys="$(awk -F: '/^physical id/{p=$2} /^core id/{seen[p":"$2]=1} END{n=0; for (k in seen) n++; print n}' /proc/cpuinfo 2>/dev/null)"
    fi
    if [ -z "$_phys" ] || [ "${_phys:-0}" -eq 0 ]; then
        _phys="$(sysctl -n hw.physicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
    fi
    case "$_phys" in ''|*[!0-9]*) _phys=0 ;; esac
    if [ "$_phys" -ge 1 ] && [ "$_phys" -le 4 ]; then
        HOST_TIER="low-end"
    else
        HOST_TIER="general"
    fi
fi
# The tag(s) that name tier-reserved work. Enrolling a tag here asserts "this
# work exists to run on the floor and a fast host running it produces WRONG
# results, not faster ones" — 855-wrr3 is the charter carrier.
# TILLANDSIAS_TIER_TAGS is a FIXTURE seam only (litmus:capability-routing-
# shape's refusal case must not depend on which roles happen to have tier
# work in the live ledger — it broke the day 861-n7f5 landed with role any).
# Enrolling a real tag still happens HERE, deliberately, never via the env.
TIER_TAGS="${TILLANDSIAS_TIER_TAGS:-low-end}"

# jq, not yq: the input is tillandsias-plan --json (pure JSON), macOS hosts
# ship jq but not yq, and the forge image installs both — Fedora's yq is the
# jq wrapper, so the swap is behavior-identical on Linux.
# A host can claim its OWN role's packets AND anything marked `any`. `query
# --role` matches the field, so it excludes `any`; `tillandsias-plan next` gets
# this right and reports a different (larger) eligible set from the same ledger.
#
# The selector used the narrow one, and it starved the sibling hosts: measured
# 2026-08-09, `query --role macos` returned 13 packets while `next macos` saw 32,
# and windows saw 7 against a budget of 3 — so a Windows cycle was being handed
# ONE packet while 56 `any` packets sat unclaimable by it. Union them, dedup by
# packet_id. The query/next divergence itself is filed as its own defect; this
# does not paper over it, it stops the selector being wrong while it is decided.
# `--claimable-by` (order 632-39p3) asks the question this script actually has:
# "what may a host of this role CLAIM", which is its own role OR `any`. It
# replaces a two-query jq union that lived here while the semantics were being
# decided. `--role` remains a substring filter on the field, which is what the
# MCP servers document and what plan_query's other consumers rely on.
# CHECK THE EXIT CODE, NOT JUST THE OUTPUT (order 644-*, windows host 2026-08-10).
#
# `raw=$(... 2>/dev/null)` followed by `[ -n "$raw" ]` treats EVERY failure of
# the query as an empty ledger. The binary is not at fault — it fails correctly:
# an unknown constraint prints `error: unknown query constraint: --claimable-by`
# and exits 2. This script threw both away, so the failure arrived as
# `refused:no-eligible-work`, which is the greedy loop's terminal state.
#
# That is the SAME counterfeit-completion defect fixed here in order 632-retq,
# walking back in through a different door. The jq preflight added then guards
# one specific dependency; this guards the whole class, because it branches on
# the tool's own verdict instead of inferring health from output volume.
#
# It is live right now, not hypothetical: `--claimable-by` landed with 632-39p3
# a few hours ago, and any host whose tillandsias-plan predates it — including
# this Windows checkout, whose binary is from an earlier build — gets an empty
# `raw` and would have been told the plan was drained.
#
# stderr is captured rather than discarded so the refusal can quote the real
# reason instead of guessing at it.
query_err="$(mktemp)"
rows="$("$PLAN" select-rows --status ready --claimable-by "$ROLE" \
    "${REL_ARG[@]+"${REL_ARG[@]}"}" --limit 400 2>"$query_err")"
query_rc=$?
if [ "$query_rc" -ne 0 ]; then
    reason="$(tr -d '\r' < "$query_err" | grep -m1 . || true)"
    rm -f "$query_err"
    # Match loosely: the wording is version-dependent, and pinning an exact
    # phrase would silently degrade the diagnosis to the generic branch on half
    # the binaries in the fleet — the failure this guard is about.
    case "$reason" in
        *"unknown query"* | *"unknown"*"select-rows"* | *"usage:"*)
            echo "refused:stale-plan-binary:${PLAN} does not support select-rows, which this script requires (${reason}); rebuild with cargo build --release -p tillandsias-plan"
            ;;
        *)
            echo "refused:query-failed:${PLAN} select-rows exited ${query_rc}: ${reason:-<no stderr>}"
            ;;
    esac
    exit 1
fi
rm -f "$query_err"

# select-rows already applied: status ready, role claimability, release,
# dependency-clearance (unresolvable ids count as BLOCKING, matching the
# resolver) and lease exclusion. The three separate refusals that used to
# distinguish those filters collapse into one, because the projection no longer
# reports which of them emptied the pool — and inventing a distinction there
# would be guessing.
#
# But EMPTY-BECAUSE-DRAINED and EMPTY-BECAUSE-BROKEN must stay distinguishable,
# and output volume cannot tell them apart: a binary that exits 0 and prints
# nothing looks exactly like a drained ledger. That is the counterfeit-completion
# defect this whole packet exists to remove, and the first draft of this rewrite
# reintroduced it — caught by this file's own negative control, which fed the
# selector a stand-in binary and got `refused:no-eligible-work`.
#
# So ask a different question instead of inferring from volume: does this binary
# DECLARE the subcommand? `capabilities` is the compile-time capability set
# (order 569), so a binary too old to project rows says so about itself.
if [ -z "$rows" ]; then
    if ! "$PLAN" capabilities 2>/dev/null | grep -qx "select-rows"; then
        echo "refused:stale-plan-binary:${PLAN} does not declare select-rows; rebuild with cargo build --release -p tillandsias-plan"
        exit 1
    fi
    echo "refused:no-eligible-work:no ready packet for role ${ROLE} is claimable, dependency-clear, and unleased"
    exit 1
fi

# ── THE TIER GATE (order 847-wgy4; operator mandate) ─────────────────────────
# A low-end host's pool is EXACTLY the tier-tagged work; everyone else's pool
# EXCLUDES it. Both directions matter: the floor host in the general queue
# produces slow duplicates, and a fast host draining the floor's profiling
# work produces measurements of the wrong machine — data that is worse than
# no data. An empty tier pool REFUSES rather than falling back to the general
# queue; the mandate says never, not "unless idle".
TIER_FILTERED=0
for tier_tag in $TIER_TAGS; do
    tier_err="$(mktemp)"
    # DELIBERATELY UNSCOPED BY RELEASE: the tier pool is small and
    # hand-curated (855-wrr3 is its charter row, filed v0.6 while v0.5 was
    # active), and profiling the floor is valuable whenever it was filed —
    # release-scoping a two-row pool idles the floor host for a bookkeeping
    # reason. The general pool it is subtracted FROM stays release-scoped, so
    # an out-of-release tier row simply never appears there to subtract.
    tier_rows="$("$PLAN" select-rows --status ready --claimable-by "$ROLE" \
        --tag "$tier_tag" --limit 400 2>"$tier_err")"
    tier_rc=$?
    if [ "$tier_rc" -ne 0 ]; then
        reason="$(tr -d '\r' < "$tier_err" | grep -m1 . || true)"
        rm -f "$tier_err"
        echo "refused:query-failed:${PLAN} select-rows --tag ${tier_tag} exited ${tier_rc}: ${reason:-<no stderr>}"
        exit 1
    fi
    rm -f "$tier_err"
    if [ "$HOST_TIER" = "low-end" ]; then
        # KEEP only the tier carriers (union across TIER_TAGS accumulates).
        TIER_POOL="${TIER_POOL:-}${TIER_POOL:+$'\n'}${tier_rows}"
    elif [ -n "$tier_rows" ]; then
        # General host: SUBTRACT the tier carriers.
        before_n="$(printf '%s\n' "$rows" | grep -c .)"
        rows="$({ printf '%s\n' "$tier_rows"; printf '==CAPDROP==\n'; printf '%s\n' "$rows"; } \
            | awk -F'\t' '
                $0 == "==CAPDROP==" { in_pool = 1; next }
                !in_pool { drop[$4] = 1; next }
                !($4 in drop)')"
        after_n="$(printf '%s\n' "$rows" | grep -c .)"
        TIER_FILTERED=$((TIER_FILTERED + before_n - after_n))
    fi
done
if [ "$HOST_TIER" = "low-end" ]; then
    rows="$(printf '%s\n' "${TIER_POOL:-}" | awk -F'\t' 'NF >= 4 && !seen[$4]++')"
    if [ -z "$rows" ]; then
        echo "refused:no-tier-work:this is a low-end host (tier gate, 847-wgy4) and no ready packet tagged [${TIER_TAGS}] is claimable by role ${ROLE} — the mandate forbids the general queue; file or free tier work rather than draining generally"
        exit 1
    fi
fi

if [ -z "$rows" ]; then
    echo "refused:no-eligible-work:every ready packet claimable by role ${ROLE} is tier-reserved for the low-end floor (tier_filtered=${TIER_FILTERED})"
    exit 1
fi

# HOST TOOL CAPABILITIES (failed-forge handoff 2026-08-15, P3; sibling of the
# order 660-z774 pool-fidelity family). pickup_role answers "which LANE may
# claim this"; it says nothing about what the HOST can actually run. The live
# selector handed 723-sazx — a p0 whose deliverable is `nix build` — to a forge
# where `command -v nix` failed, as directly-completable work, and the miss
# surfaced hours later as a GitHub 403 at push time. methodology
# distributed-work.yaml (3_filter_eligible) already requires intersecting
# capability_tags with the host's declared capabilities; the selector simply
# never implemented that intersection.
#
# THE MAP IS DELIBERATELY SMALL. A capability tag names a TOOL only when every
# packet carrying it needs that binary on the selecting host; most tags are
# TOPICS (security, forge, plan, rust...) and must never be listed here.
# Enrolling a tag asserts "no host without <binary> can make progress on ANY
# packet tagged <tag>" — assert it per tag, deliberately. `podman` (31 ready
# carriers, mixed tool/topic usage) and `cargo` are the known candidates; they
# are NOT enrolled until their carriers are audited the way nix's were.
# Format: one tag per word, tag name == probed binary name.
TOOL_CAP_TAGS="nix"

# TILLANDSIAS_HOST_CAPS, when SET (even empty), is the declared capability set
# verbatim — a space-separated list of tool names — and replaces the probes.
# That is the fixture seam and the escape hatch for a host whose probe lies.
if [ -n "${TILLANDSIAS_HOST_CAPS+x}" ]; then
    HOST_CAPS=" ${TILLANDSIAS_HOST_CAPS} "
else
    HOST_CAPS=" "
    for tool in $TOOL_CAP_TAGS; do
        command -v "$tool" >/dev/null 2>&1 && HOST_CAPS="${HOST_CAPS}${tool} "
    done
fi

# Subtract, don't project: `--tag` is the binary's own all-must-match tag
# filter, so the packets to drop come from the same projection as the pool
# (same status/claimability/release/deps-clear/unleased semantics), and a host
# with every tool present runs ZERO extra queries. Scoring, entropy, budget and
# the order-645 urgent override all run downstream of this subtraction, so a
# tool-gated p0 cannot re-enter through the urgency door.
CAPS_FILTERED=0
for tool in $TOOL_CAP_TAGS; do
    case "$HOST_CAPS" in *" ${tool} "*) continue ;; esac
    cap_err="$(mktemp)"
    cap_rows="$("$PLAN" select-rows --status ready --claimable-by "$ROLE" \
        "${REL_ARG[@]+"${REL_ARG[@]}"}" --tag "$tool" --limit 400 2>"$cap_err")"
    cap_rc=$?
    if [ "$cap_rc" -ne 0 ]; then
        reason="$(tr -d '\r' < "$cap_err" | grep -m1 . || true)"
        rm -f "$cap_err"
        # Fail LOUD, never open: silently skipping the subtraction would hand
        # tool-gated work to a host that cannot run it — the exact defect.
        echo "refused:query-failed:${PLAN} select-rows --tag ${tool} exited ${cap_rc}: ${reason:-<no stderr>}"
        exit 1
    fi
    rm -f "$cap_err"
    [ -n "$cap_rows" ] || continue
    before_n="$(printf '%s\n' "$rows" | grep -c .)"
    # Marker-line stream, same shape as the ==ROWS== scoring feed below: BSD
    # awk rejects -v values containing newlines.
    rows="$({ printf '%s\n' "$cap_rows"; printf '==CAPDROP==\n'; printf '%s\n' "$rows"; } \
        | awk -F'\t' '
            $0 == "==CAPDROP==" { in_pool = 1; next }
            !in_pool { drop[$4] = 1; next }
            !($4 in drop)')"
    after_n="$(printf '%s\n' "$rows" | grep -c .)"
    CAPS_FILTERED=$((CAPS_FILTERED + before_n - after_n))
done

if [ -z "$rows" ]; then
    echo "refused:no-eligible-work:every ready packet claimable by role ${ROLE} needs a tool this host lacks (caps_filtered=${CAPS_FILTERED}; install the tool or declare TILLANDSIAS_HOST_CAPS)"
    exit 1
fi

# ── ACCELERATOR CAPABILITY SUBTRACTION (order 847-wgy4, exit criterion 2) ────
# Same subtract-don't-project mechanism as TOOL_CAP_TAGS above, but the
# presence test reads the host's own capability-matrix row instead of
# `command -v`: a packet tagged for an accelerator this host lacks is never
# offered to it. Enrolling a tag here asserts "no host without USABLE
# <hardware> can make progress on ANY packet tagged <tag>".
#
# A host with NO matrix row (and no TILLANDSIAS_HOST_ACCELS seam) skips the
# subtraction entirely — exit criterion 4: an unprobed host degrades to
# today's behaviour, never to an emptier pool than today's.
ACCEL_CAP_TAGS="cuda rocm npu metal"
ACCEL_FILTERED=0
if [ -n "${TILLANDSIAS_HOST_ACCELS+x}" ] || [ -n "$MY_CAP_LINE" ]; then
    if [ -n "${TILLANDSIAS_HOST_ACCELS+x}" ]; then
        HOST_ACCELS=" ${TILLANDSIAS_HOST_ACCELS} "
    else
        HOST_ACCELS=" "
        _accels="$(printf '%s' "$MY_CAP_LINE" | cut -f3)"
        case "$_accels" in *"gpu:nvidia:usable"*) HOST_ACCELS="${HOST_ACCELS}cuda " ;; esac
        case "$_accels" in *"gpu:amd:usable"*)    HOST_ACCELS="${HOST_ACCELS}rocm " ;; esac
        case "$_accels" in *"npu:"*":usable"*)    HOST_ACCELS="${HOST_ACCELS}npu " ;; esac
        case "$_accels" in *"gpu:apple:usable"*)  HOST_ACCELS="${HOST_ACCELS}metal " ;; esac
    fi
    for accel in $ACCEL_CAP_TAGS; do
        case "$HOST_ACCELS" in *" ${accel} "*) continue ;; esac
        accel_err="$(mktemp)"
        accel_rows="$("$PLAN" select-rows --status ready --claimable-by "$ROLE" \
            "${REL_ARG[@]+"${REL_ARG[@]}"}" --tag "$accel" --limit 400 2>"$accel_err")"
        accel_rc=$?
        if [ "$accel_rc" -ne 0 ]; then
            reason="$(tr -d '\r' < "$accel_err" | grep -m1 . || true)"
            rm -f "$accel_err"
            echo "refused:query-failed:${PLAN} select-rows --tag ${accel} exited ${accel_rc}: ${reason:-<no stderr>}"
            exit 1
        fi
        rm -f "$accel_err"
        [ -n "$accel_rows" ] || continue
        before_n="$(printf '%s\n' "$rows" | grep -c .)"
        rows="$({ printf '%s\n' "$accel_rows"; printf '==CAPDROP==\n'; printf '%s\n' "$rows"; } \
            | awk -F'\t' '
                $0 == "==CAPDROP==" { in_pool = 1; next }
                !in_pool { drop[$4] = 1; next }
                !($4 in drop)')"
        after_n="$(printf '%s\n' "$rows" | grep -c .)"
        ACCEL_FILTERED=$((ACCEL_FILTERED + before_n - after_n))
    done
fi

if [ -z "$rows" ]; then
    echo "refused:no-eligible-work:every ready packet claimable by role ${ROLE} needs an accelerator this host lacks (accel_filtered=${ACCEL_FILTERED})"
    exit 1
fi

# The dependency graph needs EVERY ready packet, not just this role's — a linux
# packet can be the thing a macos packet is waiting on, and that downstream
# weight is exactly the "residual it is holding up" minimax asks us to maximise.
depcounts="$("$PLAN" blocking-counts "${REL_ARG[@]+"${REL_ARG[@]}"}" --limit 400 2>/dev/null)"

# Order 758-kg9p: the second empty-rows block that stood here was a
# pre-632-retq draft — it referenced `$raw`, a variable the select-rows
# migration deleted, so under `set -u` it was a latent crash wearing a
# fallback's costume, and it was unreachable anyway: every way `rows` can
# empty (query, tier gate, tool caps, accel caps) already refuses with its
# own typed verdict upstream. Removed rather than repaired — a fallback
# that cannot run and cannot be tested guards nothing.

eligible="$(printf '%s\n' "$rows" | grep -c .)"
ungrouped="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="UNGROUPED"' | grep -c .)"
grouped=$((eligible - ungrouped))
epics="$(printf '%s\n' "$rows" | awk -F'\t' '$2!="UNGROUPED"{print $2}' | sort -u | grep -c .)"
release="$(printf '%s\n' "$rows" | head -1 | cut -f6)"

# SCORE EACH EPIC (minimax; higher score = larger residual = pick sooner).
#
#   urgency  = 3 - best_priority_rank        p0 -> 3 ... p3 -> 0
#   blocking = downstream dependents of the epic's packets, capped at 10
#   neglect  = age of the epic's oldest ready packet, by order-token prefix,
#              scaled so a very old epic can outrank a merely-urgent one
#
# UNGROUPED is a real bucket, not a fallback to scatter: if it wins, the batch
# is still cohesive-by-default (budgeted, same role) and the triage line reports
# how much work has no epic, so the coverage gap gets FIXED rather than absorbed.
maxorder="$(printf '%s\n' "$rows" | awk -F'\t' '{gsub(/[^0-9].*$/,"",$3); if ($3+0>m) m=$3+0} END{print m+0}')"

# depcounts rides the input stream behind a marker line, NOT awk -v: BSD awk
# (macOS) rejects -v values containing literal newlines ("newline in string"),
# GNU awk merely tolerates them. Same dep[] map either way.
scored="$({ printf '%s\n' "$depcounts"; printf '==ROWS==\n'; printf '%s\n' "$rows"; } \
    | awk -F'\t' -v maxo="$maxorder" '
      $0 == "==ROWS==" { in_rows = 1; next }
      !in_rows {
          if ($1 != "") dep[$1] = $2 + 0;
          next
      }
      {
          e = $2; rank = $1 + 0; pid = $4;
          ord = $3; gsub(/[^0-9].*$/, "", ord); ord = ord + 0;
          # rank 99 = UNSCORED (630-6hyc): excluded from the urgency term so an
          # unknown urgency never scores as a plausible 0; counted instead.
          if (rank < 99) {
              if (!(e in best) || rank < best[e]) best[e] = rank;
              scored[e]++;
          } else {
              unscored[e]++;
          }
          if (!(e in oldest) || ord < oldest[e]) oldest[e] = ord;
          block[e] += (pid in dep) ? dep[pid] : 0;
          cnt[e]++;
          seen[e] = 1;
      }
      END {
          # urgency by best (most urgent) tier: explicit priority p0-p3 (ranks
          # 0-3) dominates every kind-derived tier (ranks 4-6). An epic with NO
          # scored packet contributes 0 urgency but is reported via unscored[].
          u[0]=3.0; u[1]=2.0; u[2]=1.0; u[3]=0.5;
          u[4]=0.4; u[5]=0.25; u[6]=0.1;
          for (e in seen) {
              urgency  = (e in best) ? u[best[e]] : 0;
              blocking = block[e] > 10 ? 10 : block[e];
              neglect  = maxo > 0 ? (10.0 * (maxo - oldest[e]) / maxo) : 0;
              score    = (2.0 * urgency) + (1.5 * blocking) + neglect;
              printf "%.3f\t%s\t%d\t%d\t%.1f\n", score, e, cnt[e], blocking, neglect;
          }
      }' \
    | sort -t"$(printf '\t')" -k1,1nr -k2,2)"

[ -n "$scored" ] || { echo "refused:no-eligible-work:could not score any epic"; exit 1; }

# UNGROUPED is not an epic and must not win on size. It scores highest whenever
# epic coverage is poor (80 of 140 eligible on 2026-08-09), and letting it win
# would hand back exactly the scattered batch this script exists to prevent —
# while hiding the gap behind a plausible-looking selection. Demote it whenever
# any real epic is available; the triage line still reports it loudly, so the
# coverage gap stays visible and gets fixed instead of absorbed.
if printf '%s\n' "$scored" | grep -qv '	UNGROUPED	'; then
    scored="$(printf '%s\n' "$scored" | awk -F'\t' '$2!="UNGROUPED"')"
fi

# ENTROPY: pick within the top-K by a seeded, reproducible index. K=1 collapses
# to pure argmax; the default K=3 keeps the choice inside the minimax frontier
# while letting the second- and third-largest residuals get worked too, so a
# permanently-second epic is not permanently starved.
epic_count="$(printf '%s\n' "$scored" | grep -c .)"
k="$TOPK"; [ "$k" -gt "$epic_count" ] && k="$epic_count"; [ "$k" -lt 1 ] && k=1
seed_num="$(printf '%s' "$SEED" | cksum | cut -d' ' -f1)"

# ── ORDINAL ROUTING (order 847-wgy4, exit criteria 1 + 3) ────────────────────
# When this host has a capability-matrix row, its pick is its ORDINAL RANK in
# the shared roster, rotated daily, over a frontier WIDENED to the roster
# size. Distinct hosts hold distinct ranks, and (rank + rot) mod width with a
# fleet-uniform rot keeps them distinct — so any two row-holding hosts get
# DISJOINT epics whenever the frontier has room, which no hash can promise
# (over 11 epics, 8 hashed hosts expect ~2.5 collisions by birthday; ordinals
# expect zero). The seeded draw below remains for rowless hosts (exit
# criterion 4) — R1 claiming still keeps THEIR collisions merely wasteful.
#
# ANTI-STARVATION IS WIDENED, NOT TRADED: width >= the old K, so every epic
# reachable yesterday is reachable today; the daily rotation walks every host
# across every frontier slot over `width` days (a permanently-second epic is
# now worked by SOME host most days, not one host occasionally); and epics
# below the frontier enter it exactly as before, by score. The rotation is a
# function of the UTC DATE alone — deriving it from the per-host seed would
# de-align the ranks and reintroduce the collisions this exists to remove.
ROUTE="seed"
if [ -n "$MY_CAP_LINE" ] && [ "$HOST_TIER" != "low-end" ]; then
    roster_n="$(printf '%s\n' "$CAP_HOSTS" | grep -c .)"
    my_rank="$(printf '%s\n' "$CAP_HOSTS" | awk -F'\t' -v h="$HOST_NAME" '$1==h{print NR; exit}')"
    if [ -n "$my_rank" ] && [ "$roster_n" -ge 1 ]; then
        width="$TOPK"
        [ "$roster_n" -gt "$width" ] && width="$roster_n"
        [ "$width" -gt "$epic_count" ] && width="$epic_count"
        [ "$width" -lt 1 ] && width=1
        # TILLANDSIAS_ROUTE_ROT pins the rotation for fixtures (the
        # anti-starvation litmus walks it); live it is a function of the UTC
        # DATE alone, fleet-uniform by construction.
        day_rot="${TILLANDSIAS_ROUTE_ROT:-$(date -u +%Y%m%d | cksum | cut -d' ' -f1)}"
        routed_pick=$(( ( (my_rank - 1 + day_rot) % width ) + 1 ))
        k="$width"
        ROUTE="rank:${my_rank}/${roster_n}:width=${width}"
    fi
fi

# SCORE-WEIGHTED, not uniform. Uniform choice over the top-K re-introduces the
# very anti-pattern minimax forbids: with scores 22.8 / 19.7 / 8.5, a uniform
# pick takes the 8.5 a third of the time — chasing a low-residual obligation
# while the maximum sits unresolved. Weighting by score keeps the largest
# residual the most likely choice by a wide margin, while leaving the smaller
# ones reachable so nothing starves. Entropy spreads coverage; it does not get
# a vote on what matters most.
# Selection probability per frontier epic: squared weights, then mixed with a
# uniform floor.
#
# SQUARED weights keep minimax dominant — linear weighting over a 19.7/8.5/5.9
# frontier left a 17% chance of working the SMALLEST residual, which is the
# shiny-packet trap wearing a different hat.
#
# The EPSILON FLOOR is what stops the sharpening from becoming starvation. Once
# release-scoping narrowed the frontier to 23.8 / 4.0 / 3.9, squared weights sent
# 94.6% to the top epic and twelve consecutive seeds all chose it — the
# anti-starvation litmus caught exactly that. Mixing in a uniform component
# guarantees every epic on the frontier a floor of EPS/k, so coverage over time
# is a property of the algorithm rather than an accident of the current score
# spread. This is plain epsilon-mixing: exploitation dominated by residual,
# exploration bounded below.
EPS="0.15"
probs="$(printf '%s\n' "$scored" | head -n "$k" \
    | awk -F'\t' -v eps="$EPS" -v k="$k" '
        { s[NR] = ($1 + 0) * ($1 + 0); name[NR] = $2; total += s[NR]; }
        END {
            for (i = 1; i <= NR; i++) {
                w = (total > 0) ? s[i] / total : 1.0 / NR;
                p = (1.0 - eps) * w + eps / k;
                printf "%.6f\t%s\n", p, name[i];
            }
        }')"

if [ "$ROUTE" != "seed" ]; then
    pick="$routed_pick"
else
    pick="$(printf '%s\n' "$probs" \
        | awk -F'\t' -v seed="$seed_num" '
            { p[NR] = $1 + 0; total += p[NR]; }
            END {
                if (total <= 0) { print 1; exit }
                r = (seed % 1000000) / 1000000.0 * total;
                acc = 0;
                for (i = 1; i <= NR; i++) {
                    acc += p[i];
                    if (r < acc) { print i; exit }
                }
                print NR;
            }')"
fi
chosen="$(printf '%s\n' "$scored" | sed -n "${pick}p" | cut -f2)"
chosen_score="$(printf '%s\n' "$scored" | sed -n "${pick}p" | cut -f1)"

[ -n "$chosen" ] || { echo "refused:no-eligible-work:could not choose an epic"; exit 1; }

batch="$(printf '%s\n' "$rows" \
    | awk -F'\t' -v e="$chosen" -v maxo="$maxorder" '
        $2==e {
            urgency = 3 - $1;
            onum = $3; gsub(/[^0-9].*$/, "", onum); onum = onum + 0;
            neglect = maxo > 0 ? (10.0 * (maxo - onum) / maxo) : 0;
            score = (2.0 * urgency) + neglect;
            printf "%.3f\t%s\n", score, $0;
        }' \
    | sort -t"$(printf '\t')" -k1,1nr -k4,4 \
    | cut -f2- \
    | head -n "$BUDGET")"

# URGENCY OVERRIDE (order 645-n3h6). Reserve slot 1 for the globally
# highest-priority eligible packet when it strictly beats everything the chosen
# epic offers.
#
# Epic selection happens BEFORE priority, and UNGROUPED is demoted whenever any
# real epic is eligible. Those two together made an ungrouped packet unreachable
# at ANY priority: a p0 and a p3 were equally invisible without a
# release_target. It was not theoretical — this host filed three p0 sibling
# smoke packets, the batches offered p3 work instead, and the p0s only surfaced
# after being hand-grouped. 107 of 160 eligible linux packets are ungrouped, so
# the same hole is open under all of them.
#
# ONE slot, and only on a STRICT priority win. That keeps the rest of the batch
# cohesive — one urgent outsider plus a cohesive remainder is still worth
# working, whereas three unrelated p0s is the scatter this selector exists to
# end. A tie does NOT displace: equal priority means the cohesive pick is
# better, because it shares context with the rest of the batch.
top_urgent="$(printf '%s\n' "$rows" \
    | sort -t"$(printf '\t')" -k1,1n -k3,3 -k4,4 \
    | head -1)"
if [ -n "$top_urgent" ] && [ -n "$batch" ]; then
    urgent_rank="$(printf '%s' "$top_urgent" | cut -f1)"
    batch_rank="$(printf '%s\n' "$batch" | cut -f1 | sort -n | head -1)"
    urgent_pid="$(printf '%s' "$top_urgent" | cut -f4)"
    if [ "${urgent_rank:-9}" -lt "${batch_rank:-9}" ] \
       && ! printf '%s\n' "$batch" | cut -f4 | grep -qxF "$urgent_pid"; then
        # Prepend it and drop the batch's LAST entry, so the budget still holds.
        batch="$({ printf '%s\n' "$top_urgent"
                   printf '%s\n' "$batch" | head -n $((BUDGET - 1)); })"
        URGENT_NOTE="$urgent_pid"
    fi
fi

# HARNESS AFFINITY (order 555). The routing enabler for the operator's "run
# plain meta-orchestration in a harness and it picks its own tests" ask: a
# forge cycle that knows which harness drives it (TILLANDSIAS_AGENT, set by
# the launch profile — its absence in live forges is order 570's gap) MUST
# prefer a ready packet tagged [harness-validation, <that harness>] over the
# general backlog, so an OpenCode forge claims the OpenCode validation packet
# instead of a random platform packet. Scoped to forges: a bare-metal host
# runs many harnesses and proves nothing about any one of them.
#
# The affinity pick takes the batch HEAD — above the order-645 urgent slot —
# because a validation forge that defers its own validation to global
# urgencies never validates its harness; non-forge hosts never enter this
# branch, so urgent work still preempts everywhere else. No matching ready
# packet, or an agent name outside the tag-safe charset, leaves the batch
# untouched (fallback, never idle). The query reuses select-rows' all-match
# --tag semantics — the same lane the tier gate above already trusts — and is
# DELIBERATELY UNSCOPED BY RELEASE for the tier pool's reason: the
# harness-validation pool is small and hand-curated, and validating THIS
# harness is valuable whenever its packet was filed.
HARNESS_NOTE=""
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ] && [ -n "${TILLANDSIAS_AGENT:-}" ] && [ -n "$batch" ]; then
    case "$TILLANDSIAS_AGENT" in
        *[!a-z0-9-]* | '') : ;; # not a tag-shaped harness name; fall back
        *)
            harness_rows="$("$PLAN" select-rows --status ready --claimable-by "$ROLE" \
                --tag harness-validation --tag "$TILLANDSIAS_AGENT" --limit 5 2>/dev/null)" || harness_rows=""
            harness_row="$(printf '%s\n' "$harness_rows" | awk -F'\t' 'NF >= 4' \
                | sort -t"$(printf '\t')" -k1,1n -k3,3 -k4,4 | head -1)"
            if [ -n "$harness_row" ]; then
                harness_pid="$(printf '%s' "$harness_row" | cut -f4)"
                if printf '%s\n' "$batch" | cut -f4 | grep -qxF "$harness_pid"; then
                    # Already in the chosen epic's batch: move it to the head
                    # rather than duplicate it.
                    batch="$({ printf '%s\n' "$harness_row"
                               printf '%s\n' "$batch" | awk -F'\t' -v p="$harness_pid" '$4 != p'; })"
                else
                    batch="$({ printf '%s\n' "$harness_row"
                               printf '%s\n' "$batch" | head -n $((BUDGET - 1)); })"
                fi
                HARNESS_NOTE="$harness_pid"
            fi
            ;;
    esac
fi

size="$(printf '%s\n' "$batch" | grep -c .)"

printf 'batch: epic=%s role=%s release=%s size=%s budget=%s score=%s seed=%s pick=%s/%s%s%s%s\n' \
    "$chosen" "$ROLE" "$release" "$size" "$BUDGET" "$chosen_score" "$SEED" "$pick" "$k" \
    "$( if [ "$HOST_TIER" = "low-end" ]; then printf ' route=tier:low-end'; elif [ "$ROUTE" != "seed" ]; then printf ' route=%s' "$ROUTE"; fi )" \
    "$( [ -n "${URGENT_NOTE:-}" ] && printf ' urgent=%s' "$URGENT_NOTE" )" \
    "$( [ -n "${HARNESS_NOTE:-}" ] && printf ' harness=%s' "$HARNESS_NOTE" )"
printf '%s\n' "$batch" | while IFS=$'\t' read -r rank epic order pid prio rel; do
    [ -n "$pid" ] || continue
    printf 'packet\t%s\t%s\t%s\n' "$order" "$pid" "$prio"
done
# urgency_unscored (630-6hyc): ready packets with NEITHER an explicit priority
# NOR a kind that maps to an urgency tier — rank 99. Reported so a missing
# urgency signal is VISIBLE and gets fixed (backfill priority/kind), never
# absorbed as a silent zero the way the old `// "p3"` default hid it.
urgency_unscored="$(printf '%s\n' "$rows" | awk -F'\t' '$1==99' | grep -c .)"
# caps_filtered rides the triage line ONLY when the host-capability subtraction
# dropped rows (same conditional idiom as the header's `urgent=`), so a fully
# capable host emits byte-identical output to the pre-filter selector.
printf 'triage: eligible=%s grouped=%s ungrouped=%s epics=%s urgency_unscored=%s%s%s%s\n' \
    "$eligible" "$grouped" "$ungrouped" "$epics" "$urgency_unscored" \
    "$( [ "${CAPS_FILTERED:-0}" -gt 0 ] && printf ' caps_filtered=%s' "$CAPS_FILTERED" )" \
    "$( [ "${TIER_FILTERED:-0}" -gt 0 ] && printf ' tier_filtered=%s' "$TIER_FILTERED" )" \
    "$( [ "${ACCEL_FILTERED:-0}" -gt 0 ] && printf ' accel_filtered=%s' "$ACCEL_FILTERED" )"
# The frontier is printed so a cycle can justify its choice, and so a human can
# see what it did NOT pick. An unexplained selection is unauditable.
printf '%s\n' "$scored" | head -n "$k" | while IFS=$'\t' read -r sc e c b n; do
    p="$(printf '%s\n' "$probs" | awk -F'\t' -v e="$e" '$2==e {printf "%.3f", $1}')"
    printf 'frontier\t%s\t%s\tpackets=%s\tblocking=%s\tneglect=%s\tp=%s\n' "$sc" "$e" "$c" "$b" "$n" "${p:-?}"
done
