#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:575
#
# Cycle metrics — what a meta-orchestration cycle reports about ITSELF when it
# ends, in one pinned grammar.
#
# WHY THIS EXISTS AND WHAT IT DELIBERATELY DOES NOT DO
#
# The operator asked for cycle metrics covering tool usage, success and
# efficiency rates, and — the hard one — metrics PROVING the experts are used
# AND useful. Those are two different questions and a single counter answers
# neither honestly:
#
#   USED     is a volume question. Easy to measure, easy to game, and on its own
#            it says nothing about value.
#   USEFUL   is a quality question. An expert called two hundred times that
#            refuses two hundred times is heavily used and completely useless.
#
# Order 531 was exactly that failure in the wild: the plan expert returned
# `confidence=unsupported` for every single query — because the forge had been
# seeded from a branch with no expert sources — while the launch state truthfully
# reported `experts: ready` and every health signal read green. A call counter
# would have shown healthy adoption throughout. So the ratio this script reports
# as the headline is ANSWER RATE, not call count.
#
# ANTI-GAMING, stated so it survives future edits: `answered` is only reachable
# when the expert returns CITATIONS, and the compiled binary emits citations only
# when it resolved a real packet or a real YAML path. Calling a tool more times
# cannot raise the answer rate; only answering more can. Any future change that
# lets `answered` be reached without citations breaks this property and must be
# rejected on that ground — the same reasoning that keeps XP constraint-derived
# rather than activity-derived (see packet 567).
#
# WHAT IS NOT MEASURABLE FROM HERE, stated rather than faked:
#   - SUBSTITUTION ("did the agent query the expert INSTEAD of grepping the
#     ledger?") is the metric that would best prove adoption. It needs the
#     AGENT's own tool-call log, which lives in the harness, not in this repo.
#     This script cannot see it and does not pretend to. Reported as `unknown`.
#   - Token spend and wall-clock efficiency likewise belong to the harness.
# Reporting a number we cannot derive would be worse than reporting none: it
# would make an unmeasured thing look measured.
#
# PINNED GRAMMAR (one `key=value` line per block; agents and CI branch on these,
# never on the prose):
#   experts: calls=<n> answered=<n> unsupported=<n> degraded=<n> errors=<n> \
#            answer_rate=<pct|-> tools=<csv|-> source=<path|absent>
#   plan:    packets=<n> ready=<n> blocked=<n> pending=<n>
#   repo:    commits_this_cycle=<n|-> worktree=<clean|dirty> traces=<current|stale|unknown>
#   verdict: <ok|attention>:<reason>
#
# Exit status is 0 whenever the report was produced. A metrics reporter that
# fails the cycle it is measuring is a metric that can take down what it
# measures; the VERDICT carries the judgement instead.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

USAGE_LOG="${TILLANDSIAS_EXPERT_USAGE_LOG:-/tmp/forge-expert-usage.jsonl}"
SINCE_REF="${1:-}"

# ── experts ─────────────────────────────────────────────────────────────────
calls=0
answered=0
unsupported=0
degraded=0
errors=0
tools="-"
source_state="absent"

if [ -r "$USAGE_LOG" ]; then
    source_state="$USAGE_LOG"
    # jq is the only parser used anywhere in the expert path (no python —
    # methodology tlatoani_hard_no_python). A malformed line must not abort the
    # report, so every read tolerates failure.
    # `grep -c` PRINTS "0" and EXITS 1 when nothing matches, so the obvious
    # `$(grep -c ... || echo 0)` captures BOTH grep's zero and echo's zero and
    # yields the two-line value "0\n0" — which then corrupts every subsequent
    # field of a space-separated grammar line. Assign first, default after.
    calls=$(grep -c . "$USAGE_LOG" 2>/dev/null) || calls=0
    answered=$(grep -c '"outcome":"answered"' "$USAGE_LOG" 2>/dev/null) || answered=0
    unsupported=$(grep -c '"outcome":"unsupported"' "$USAGE_LOG" 2>/dev/null) || unsupported=0
    degraded=$(grep -c '"outcome":"degraded"' "$USAGE_LOG" 2>/dev/null) || degraded=0
    errors=$(grep -c '"outcome":"error"' "$USAGE_LOG" 2>/dev/null) || errors=0
    # `jq -r` renders a missing key as the literal string "null", which would be
    # reported as a tool name. Drop those rather than print a word no tool has.
    t=$(jq -r '.tool // empty' "$USAGE_LOG" 2>/dev/null | sort -u | paste -sd, - 2>/dev/null || true)
    [ -n "$t" ] && tools="$t"
fi

# The denominator is answered + unsupported: calls where the expert RAN and
# either resolved the question or refused it. `degraded` (the expert could not
# run at all) and `error` (protocol) are excluded deliberately — a broken build
# is an infrastructure fact, and folding it in would make a wrong artifact look
# like a hard question. That conflation is precisely what hid order 531.
answer_rate="-"
graded=$((answered + unsupported))
if [ "$graded" -gt 0 ]; then
    answer_rate="$(( answered * 100 / graded ))%"
fi

printf 'experts: calls=%s answered=%s unsupported=%s degraded=%s errors=%s answer_rate=%s tools=%s source=%s\n' \
    "$calls" "$answered" "$unsupported" "$degraded" "$errors" "$answer_rate" "$tools" "$source_state"
printf 'experts_substitution: unknown (needs the agent harness tool log; not derivable in-repo)\n'

# ── plan ────────────────────────────────────────────────────────────────────
packets="-"; ready="-"; blocked="-"; pending="-"
PLAN_BIN=""
for cand in "$REPO_ROOT/target/release/tillandsias-plan" \
            "$HOME/.local/bin/tillandsias-plan" \
            "$(command -v tillandsias-plan 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then PLAN_BIN="$cand"; break; fi
done
if [ -n "$PLAN_BIN" ]; then
    chk="$("$PLAN_BIN" check 2>/dev/null | tail -1 || true)"
    case "$chk" in
        ok:*packets*) packets="$(printf '%s' "$chk" | sed -n 's/.*ok: \([0-9]*\) packets.*/\1/p')" ;;
    esac
    ready="$("$PLAN_BIN" ready 2>/dev/null | grep -c .)" || ready=0
fi
printf 'plan: packets=%s ready=%s plan_bin=%s\n' \
    "${packets:--}" "${ready:--}" "${PLAN_BIN:-absent}"

# ── repo ────────────────────────────────────────────────────────────────────
worktree="unknown"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
        worktree="clean"
    else
        worktree="dirty"
    fi
fi
commits="-"
if [ -n "$SINCE_REF" ] && git -C "$REPO_ROOT" rev-parse --verify "$SINCE_REF" >/dev/null 2>&1; then
    commits="$(git -C "$REPO_ROOT" rev-list --count "${SINCE_REF}..HEAD" 2>/dev/null || echo -)"
fi
traces="unknown"
if [ -x "$REPO_ROOT/scripts/generate-traces.sh" ]; then
    if out="$("$REPO_ROOT/scripts/generate-traces.sh" --check 2>/dev/null)"; then
        case "$out" in
            *ok:trace-indexes-current*) traces="current" ;;
            *stale:trace-indexes*) traces="stale" ;;
        esac
    else
        traces="stale"
    fi
fi
printf 'repo: commits_this_cycle=%s worktree=%s traces=%s\n' "$commits" "$worktree" "$traces"

# ── verdict ─────────────────────────────────────────────────────────────────
# Named reasons only. "attention" is not a failure — it is the cycle telling its
# operator which single fact to look at first.
verdict="ok:nothing-flagged"
if [ "$worktree" = "dirty" ]; then
    verdict="attention:worktree-dirty"
elif [ "$traces" = "stale" ]; then
    verdict="attention:trace-indexes-stale"
elif [ "$degraded" -gt 0 ]; then
    verdict="attention:experts-degraded-${degraded}-calls-could-not-run"
elif [ "$graded" -gt 0 ] && [ "$answered" -eq 0 ]; then
    # The order-531 signature: the expert ran every time and answered nothing.
    verdict="attention:expert-answered-nothing-check-base-branch"
elif [ "$calls" -eq 0 ]; then
    verdict="attention:experts-never-called"
fi
printf 'verdict: %s\n' "$verdict"
exit 0
