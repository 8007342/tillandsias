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

# --experts-only prints just the expert blocks and skips the plan/repo/verdict
# work. Those blocks shell out to `tillandsias-plan check` and
# `generate-traces.sh --check`, which are real scans over the whole repo and take
# seconds; the expert numbers are pure arithmetic over one log. Worth having as
# its own mode rather than a test-only affordance: "how are the experts doing
# right now" is the question asked most often, and it should not cost a repo
# scan.
EXPERTS_ONLY=false
SINCE_REF=""
for arg in "$@"; do
    case "$arg" in
        --experts-only) EXPERTS_ONLY=true ;;
        *) [ -z "$SINCE_REF" ] && SINCE_REF="$arg" ;;
    esac
done

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
    # The `experts:` block measures the PLAN/METHODOLOGY EXPERT specifically —
    # its answer-rate is a property of that one server. Packet 682-m8ek made the
    # OTHER MCP servers (project-info, git-tools) write to this same log, tagged
    # with a `server` field. Counting their rows here would inflate the expert's
    # call/answer counts with non-expert traffic, so scope to the expert's rows:
    # legacy rows (written before the field existed — all plan-expert) plus rows
    # explicitly tagged `server":"forge-plan`. On a legacy-only log this is the
    # whole file, so the reported numbers are byte-identical to before.
    PLAN_STREAM="$( { grep -v '"server":"' "$USAGE_LOG"; grep '"server":"forge-plan"' "$USAGE_LOG"; } 2>/dev/null )"
    # jq is the only parser used anywhere in the expert path (no python —
    # methodology tlatoani_hard_no_python). A malformed line must not abort the
    # report, so every read tolerates failure.
    # `grep -c` PRINTS "0" and EXITS 1 when nothing matches, so the obvious
    # `$(grep -c ... || echo 0)` captures BOTH grep's zero and echo's zero and
    # yields the two-line value "0\n0" — which then corrupts every subsequent
    # field of a space-separated grammar line. Assign first, default after.
    calls=$(printf '%s\n' "$PLAN_STREAM" | grep -c . 2>/dev/null) || calls=0
    answered=$(printf '%s\n' "$PLAN_STREAM" | grep -c '"outcome":"answered"' 2>/dev/null) || answered=0
    unsupported=$(printf '%s\n' "$PLAN_STREAM" | grep -c '"outcome":"unsupported"' 2>/dev/null) || unsupported=0
    degraded=$(printf '%s\n' "$PLAN_STREAM" | grep -c '"outcome":"degraded"' 2>/dev/null) || degraded=0
    errors=$(printf '%s\n' "$PLAN_STREAM" | grep -c '"outcome":"error"' 2>/dev/null) || errors=0
    # `jq -r` renders a missing key as the literal string "null", which would be
    # reported as a tool name. Drop those rather than print a word no tool has.
    t=$(printf '%s\n' "$PLAN_STREAM" | jq -r '.tool // empty' 2>/dev/null | sort -u | paste -sd, - 2>/dev/null || true)
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

# ── mcp usage (packets 682-ym68, 682-m8ek) ───────────────────────────────────
# "Are the servers used?" — per-server call volume, distinct from answer_rate's
# "are they right?". Packet 682-m8ek added a `server` field to the usage JSONL
# and instrumented every MCP server (forge-plan, project-info, git-tools), so
# this line now reports REAL per-server counts by grouping on that field.
#
# LEGACY FALLBACK: rows written before 682-m8ek carry no `server` field. When
# the log contains no tagged rows at all, keep the exact pre-682-m8ek line
# (distinct tools as a server proxy, the rest NAMED uninstrumented) rather than
# fabricating zeros — this is what keeps the shape byte-identical on old logs.
if grep -q '"server":"' "$USAGE_LOG" 2>/dev/null; then
    # Real per-server counts. grep|sed|sort|uniq (no python); tolerant of
    # malformed lines. `legacy_untagged` counts any pre-682-m8ek rows still in
    # the same log so the total is not silently under-reported.
    per_server="$(grep -o '"server":"[^"]*"' "$USAGE_LOG" 2>/dev/null \
        | sed 's/.*:"//; s/"$//' | sort | uniq -c \
        | awk '{printf "%s%s=%s", (NR>1?";":""), $2, $1}')"
    [ -n "$per_server" ] || per_server="-"
    mcp_servers=$(grep -o '"server":"[^"]*"' "$USAGE_LOG" 2>/dev/null \
        | sed 's/.*:"//; s/"$//' | sort -u | grep -c .) || mcp_servers=0
    legacy_untagged=$(grep -vc '"server":"' "$USAGE_LOG" 2>/dev/null) || legacy_untagged=0
    printf 'mcp: servers=%s per_server=%s legacy_untagged=%s source=%s\n' \
        "$mcp_servers" "$per_server" "$legacy_untagged" "$source_state"
else
    mcp_servers=0
    if [ "$tools" != "-" ]; then
        mcp_servers=$(printf '%s' "$tools" | tr ',' '\n' | grep -c .)
    fi
    printf 'mcp: servers=%s plan-expert-calls=%s other-servers=uninstrumented-see-682-m8ek source=%s\n' \
        "$mcp_servers" "$calls" "$source_state"
fi

# ── expert accuracy (packet 682-ym68) ────────────────────────────────────────
# The groundtruth PASS-RATE — "are the experts RIGHT?" — graded against the
# committed rung-1 query set (openspec/litmus-tests/groundtruth/). This is
# distinct from answer_rate: an expert can answer every question (high
# answer_rate) while citing spans that do not support the answer (low accuracy).
# Accuracy is pass/total of graded cases, never call volume. The grader is cheap
# (~0.4s over 19 cases) so it runs every cycle; if no binary can grade, the line
# defers to the litmus gate rather than reporting a number the tooling did not
# produce.
GRADE_BIN=""
for cand in "$REPO_ROOT/target/release/tillandsias-plan" \
            "$HOME/.local/bin/tillandsias-plan" \
            "$(command -v tillandsias-plan 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then GRADE_BIN="$cand"; break; fi
done
accuracy_line='expert_accuracy: deferred source=litmus:expert-groundtruth-harness'
if [ -n "$GRADE_BIN" ]; then
    gr="$(cd "$REPO_ROOT" && ( command -v timeout >/dev/null 2>&1 && timeout 30 "$GRADE_BIN" grade --root . || "$GRADE_BIN" grade --root . ) 2>/dev/null | grep '^groundtruth-result:' | tail -1)"
    if [ -n "$gr" ]; then
        gp="$(printf '%s' "$gr" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
        gt="$(printf '%s' "$gr" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
        if [ -n "$gp" ] && [ -n "$gt" ] && [ "$gt" -gt 0 ]; then
            accuracy_line="expert_accuracy: pass=${gp} total=${gt} rate=$(( gp * 100 / gt ))% source=groundtruth-rung1"
        fi
    fi
fi
printf '%s\n' "$accuracy_line"

if [ "$EXPERTS_ONLY" = true ]; then
    exit 0
fi

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
