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
#   ^refused:(no-eligible-work|no-plan-binary|missing-tool|parse-failure|bad-role):.*$
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
# Default seed = host kind + UTC date, so one host varies day to day and two
# hosts on the same day diverge.
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

# jq is load-bearing for every projection below. Absence is an environment
# fault, never a statement about the ledger — refuse with its own token.
#
# TILLANDSIAS_JQ exists so the litmus can exercise the absent-jq path without
# emptying PATH (which kills the shebang before the script ever runs). It names
# the binary only; the script never invokes it by that variable, so it cannot be
# used to smuggle in a different projector.
command -v "${TILLANDSIAS_JQ:-jq}" >/dev/null 2>&1 || {
    echo "refused:missing-tool:jq is not on PATH (required to project tillandsias-plan --json); this is NOT a drained ledger"
    exit 1
}

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
    SEED="${TILLANDSIAS_HOST_KIND:-host}-$(date -u +%Y%m%d)"
fi

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
raw="$("$PLAN" query --status ready --claimable-by "$ROLE" "${REL_ARG[@]+"${REL_ARG[@]}"}" --limit 400 --json 2>/dev/null)"
[ -n "$raw" ] && [ "$raw" != "[]" ] || { echo "refused:no-eligible-work:query returned nothing for role ${ROLE}"; exit 1; }

# The dependency graph needs EVERY ready packet, not just this role's — a linux
# packet can be the thing a macos packet is waiting on, and that downstream
# weight is exactly the "residual it is holding up" minimax asks us to maximise.
allraw="$("$PLAN" query --status ready "${REL_ARG[@]+"${REL_ARG[@]}"}" --limit 400 --json 2>/dev/null)"
depcounts="$(printf '%s' "$allraw" | jq -r '.[] | .depends_on[]?' 2>/dev/null | sort | uniq -c | awk '{print $2"\t"$1}')"

# Flatten to: priority_rank \t epic \t order \t packet_id \t priority
rows="$(printf '%s' "$raw" | jq -r '
  .[]
  | [ (.priority // "p3"), (.release_target // "UNGROUPED"), (.order|tostring), .packet_id, (.desired_release // "?") ]
  | @tsv' 2>/dev/null \
  | awk -F'\t' '{
        rank = ($1=="p0"?0:($1=="p1"?1:($1=="p2"?2:3)));
        print rank "\t" $2 "\t" $3 "\t" $4 "\t" $1 "\t" $5;
    }')"

if [ -z "$rows" ]; then
    # Distinguish "the query returned an empty array" (a real terminal state)
    # from "the query returned packets and the projection dropped them" (a
    # tooling fault). `[]` is 2 bytes; anything longer carried packets.
    if [ "${#raw}" -gt 2 ]; then
        echo "refused:parse-failure:tillandsias-plan returned ${#raw} bytes for role ${ROLE} but the jq projection yielded no rows"
        exit 1
    fi
    echo "refused:no-eligible-work:no ready packets for role ${ROLE}"
    exit 1
fi

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
    p="$(printf '%s\n' "$probs" | awk -F'\t' -v e="$e" '$2==e {printf "%.3f", $1}')"
    printf 'frontier\t%s\t%s\tpackets=%s\tblocking=%s\tneglect=%s\tp=%s\n' "$sc" "$e" "$c" "$b" "$n" "${p:-?}"
done
