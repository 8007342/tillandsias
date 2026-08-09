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
#   ^batch: epic=<id|UNGROUPED> role=<r> release=<v> size=<n> budget=<n>$
#   ^packet\t<order>\t<packet_id>\t<priority>$
#   ^triage: eligible=<n> grouped=<n> ungrouped=<n> epics=<n>$
# or exactly one refusal line:
#   ^refused:(no-eligible-work|no-plan-binary|bad-role):.*$
# Exit 0 on a batch, 1 on refusal.
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
# Default seed = host kind + UTC date, so one host varies day to day and two
# hosts on the same day diverge.

set -uo pipefail

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

PLAN=""
for c in ./target/release/tillandsias-plan ./target/debug/tillandsias-plan "$(command -v tillandsias-plan 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { PLAN="$c"; break; }
done
[ -n "$PLAN" ] || { echo "refused:no-plan-binary:build with cargo build --release -p tillandsias-plan"; exit 1; }

# DEFAULT BUDGET. Forge cycles take at most ONE packet — decided by The Tlatoani
# 2026-07-10 (order 264) because a litmus-launched forge lives inside a 600s
# step budget. That rule predates this script and is not relaxed by it.
if [ -z "$BUDGET" ]; then
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        BUDGET=1
    else
        BUDGET=3
    fi
fi
case "$BUDGET" in ''|*[!0-9]*) echo "refused:bad-role:budget must be a positive integer"; exit 1 ;; esac
[ "$BUDGET" -ge 1 ] || { echo "refused:bad-role:budget must be >= 1"; exit 1; }

REL_ARG=()
[ -n "$RELEASE" ] && REL_ARG=(--release "$RELEASE")

if [ -z "$SEED" ]; then
    SEED="${TILLANDSIAS_HOST_KIND:-host}-$(date -u +%Y%m%d)"
fi

raw="$("$PLAN" query --status ready --role "$ROLE" "${REL_ARG[@]}" --limit 400 --json 2>/dev/null)"
[ -n "$raw" ] || { echo "refused:no-eligible-work:query returned nothing for role ${ROLE}"; exit 1; }

# The dependency graph needs EVERY ready packet, not just this role's — a linux
# packet can be the thing a macos packet is waiting on, and that downstream
# weight is exactly the "residual it is holding up" minimax asks us to maximise.
allraw="$("$PLAN" query --status ready "${REL_ARG[@]}" --limit 400 --json 2>/dev/null)"
depcounts="$(printf '%s' "$allraw" | yq -r '.[] | .depends_on[]?' 2>/dev/null | sort | uniq -c | awk '{print $2"\t"$1}')"

# Flatten to: priority_rank \t epic \t order \t packet_id \t priority
rows="$(printf '%s' "$raw" | yq -r '
  .[]
  | [ (.priority // "p3"), (.release_target // "UNGROUPED"), (.order|tostring), .packet_id, (.desired_release // "?") ]
  | @tsv' 2>/dev/null \
  | awk -F'\t' '{
        rank = ($1=="p0"?0:($1=="p1"?1:($1=="p2"?2:3)));
        print rank "\t" $2 "\t" $3 "\t" $4 "\t" $1 "\t" $5;
    }')"

[ -n "$rows" ] || { echo "refused:no-eligible-work:no ready packets for role ${ROLE}"; exit 1; }

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

scored="$(printf '%s\n' "$rows" \
    | awk -F'\t' -v maxo="$maxorder" -v deps="$depcounts" '
      BEGIN {
          n = split(deps, dl, "\n");
          for (i = 1; i <= n; i++) { split(dl[i], kv, "\t"); if (kv[1] != "") dep[kv[1]] = kv[2] + 0; }
      }
      {
          e = $2; rank = $1 + 0; pid = $4;
          ord = $3; gsub(/[^0-9].*$/, "", ord); ord = ord + 0;
          if (!(e in best) || rank < best[e]) best[e] = rank;
          if (!(e in oldest) || ord < oldest[e]) oldest[e] = ord;
          block[e] += (pid in dep) ? dep[pid] : 0;
          cnt[e]++;
      }
      END {
          for (e in best) {
              urgency  = 3 - best[e];
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

# SCORE-WEIGHTED, not uniform. Uniform choice over the top-K re-introduces the
# very anti-pattern minimax forbids: with scores 22.8 / 19.7 / 8.5, a uniform
# pick takes the 8.5 a third of the time — chasing a low-residual obligation
# while the maximum sits unresolved. Weighting by score keeps the largest
# residual the most likely choice by a wide margin, while leaving the smaller
# ones reachable so nothing starves. Entropy spreads coverage; it does not get
# a vote on what matters most.
pick="$(printf '%s\n' "$scored" | head -n "$k" \
    | awk -F'\t' -v seed="$seed_num" '
        { s[NR] = $1 + 0; total += s[NR]; }
        END {
            if (total <= 0) { print 1; exit }
            # Deterministic point in [0,total) from the seed.
            r = (seed % 100000) / 100000.0 * total;
            acc = 0;
            for (i = 1; i <= NR; i++) {
                acc += s[i];
                if (r < acc) { print i; exit }
            }
            print NR;
        }')"
chosen="$(printf '%s\n' "$scored" | sed -n "${pick}p" | cut -f2)"
chosen_score="$(printf '%s\n' "$scored" | sed -n "${pick}p" | cut -f1)"

[ -n "$chosen" ] || { echo "refused:no-eligible-work:could not choose an epic"; exit 1; }

batch="$(printf '%s\n' "$rows" \
    | awk -F'\t' -v e="$chosen" '$2==e' \
    | sort -t"$(printf '\t')" -k1,1n -k3,3 -k4,4 \
    | head -n "$BUDGET")"

size="$(printf '%s\n' "$batch" | grep -c .)"

printf 'batch: epic=%s role=%s release=%s size=%s budget=%s score=%s seed=%s pick=%s/%s\n' \
    "$chosen" "$ROLE" "$release" "$size" "$BUDGET" "$chosen_score" "$SEED" "$pick" "$k"
printf '%s\n' "$batch" | while IFS=$'\t' read -r rank epic order pid prio rel; do
    [ -n "$pid" ] || continue
    printf 'packet\t%s\t%s\t%s\n' "$order" "$pid" "$prio"
done
printf 'triage: eligible=%s grouped=%s ungrouped=%s epics=%s\n' \
    "$eligible" "$grouped" "$ungrouped" "$epics"
# The frontier is printed so a cycle can justify its choice, and so a human can
# see what it did NOT pick. An unexplained selection is unauditable.
printf '%s\n' "$scored" | head -n "$k" | while IFS=$'\t' read -r sc e c b n; do
    printf 'frontier\t%s\t%s\tpackets=%s\tblocking=%s\tneglect=%s\n' "$sc" "$e" "$c" "$b" "$n"
done
