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
#   flow:    cycles=<n> avg_completed_per_cycle=<x> avg_commits_per_cycle=<y> \
#            overhead_ratio=<commits-per-completed|-> source=<path|absent>
#   repo:    commits_this_cycle=<n|-> worktree=<clean|dirty> traces=<current|stale|unknown>
#   verdict: <ok|attention>:<reason>
#
# THE `flow:` LINE and its emitter (packet 682-epud). The greedier-batching
# hypothesis (682-yiz7) asks whether LARGER batches per cycle amortize the fixed
# meta-orchestration overhead. That is a MEASUREMENT question and cannot be
# answered from a single cycle: you need packets-consumed vs cycle overhead
# across MANY cycles. So each cycle APPENDS one packet-flow record to a per-host
# JSONL log (${TILLANDSIAS_CYCLE_FLOW_LOG}) via the `--emit-flow` subcommand, and
# this reporter reports the ROLLING view over that log. `overhead_ratio` is the
# number the 682-yiz7 decision consumes: commits (the per-cycle cost) per
# completed packet (the work done). If greedier batches amortize overhead, this
# ratio FALLS as batch size rises. The emit is best-effort by construction (a
# metric may never fail the cycle it measures), exactly like mcp-usage-log.sh.
#
# EMIT GRAMMAR (append one record; never fails):
#   cycle-metrics.sh --emit-flow host=<h> batch_epic=<id> batch_seed=<s> \
#       batch_size=<n> budget=<n> claimed=<n> completed=<n> filed=<n> \
#       commits=<n> plan_open=<n> plan_total=<n>
#   → {"ts":<utc>,"host":<h>,"batch_epic":<id>,"batch_seed":<s>,
#      "batch_size":<n>,"budget":<n>,"claimed":<n>,"completed":<n>,"filed":<n>,
#      "commits":<n>,"plan_open":<n>,"plan_total":<n>}
#
# Exit status is 0 whenever the report was produced. A metrics reporter that
# fails the cycle it is measuring is a metric that can take down what it
# measures; the VERDICT carries the judgement instead.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

USAGE_LOG="${TILLANDSIAS_EXPERT_USAGE_LOG:-/tmp/forge-expert-usage.jsonl}"
FLOW_LOG="${TILLANDSIAS_CYCLE_FLOW_LOG:-/tmp/tillandsias-cycle-flow.jsonl}"
TIMING_LOG="${TILLANDSIAS_TIMING_LOG:-/tmp/tillandsias-timing.jsonl}"

# ── --emit-timing: append one build/test/litmus DURATION record (packet 682-emvg)
# Best-effort by construction, mirroring --emit-flow above and mcp-usage-log.sh:
# the whole append is wrapped so a full disk, a read-only path, or a missing
# `date` cannot take down the build/test/litmus step being measured. Always exits
# 0. Accepts key=value tokens in any order; absent numeric fields default to 0,
# absent strings to "-". "time spent building, testing" is the most likely
# bottleneck and was invisible until this rung existed.
if [ "${1:-}" = "--emit-timing" ]; then
    shift
    et_host="-"; et_step="-"; et_phase="-"
    et_duration_ms=0; et_exit=0
    for tok in "$@"; do
        case "$tok" in
            host=*)         et_host="${tok#host=}" ;;
            step=*)         et_step="${tok#step=}" ;;
            phase=*)        et_phase="${tok#phase=}" ;;
            duration_ms=*)  et_duration_ms="${tok#duration_ms=}" ;;
            exit=*)         et_exit="${tok#exit=}" ;;
        esac
    done
    # Numeric fields must be integers or the rolling arithmetic downstream breaks;
    # coerce any non-numeric to 0 rather than write a poisoned record.
    for v in et_duration_ms et_exit; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
    {
        et_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '{"ts":"%s","host":"%s","step":"%s","phase":"%s","duration_ms":%s,"exit":%s}\n' \
            "$et_ts" "$et_host" "$et_step" "$et_phase" \
            "$et_duration_ms" "$et_exit" \
            >>"$TIMING_LOG"
    } 2>/dev/null || true
    exit 0
fi

# ── --emit-flow: append one per-cycle packet-flow record (packet 682-epud) ────
# Best-effort by construction, mirroring images/.../mcp-usage-log.sh: the whole
# append is wrapped so a full disk, a read-only path, or a missing `date` cannot
# take down the cycle being measured. Always exits 0. Accepts key=value tokens in
# any order; absent numeric fields default to 0, absent strings to "-".
if [ "${1:-}" = "--emit-flow" ]; then
    shift
    ef_host="-"; ef_epic="-"; ef_seed="-"
    ef_batch_size=0; ef_budget=0; ef_claimed=0; ef_completed=0; ef_filed=0
    ef_commits=0; ef_plan_open=0; ef_plan_total=0
    for tok in "$@"; do
        case "$tok" in
            host=*)        ef_host="${tok#host=}" ;;
            batch_epic=*)  ef_epic="${tok#batch_epic=}" ;;
            batch_seed=*)  ef_seed="${tok#batch_seed=}" ;;
            batch_size=*)  ef_batch_size="${tok#batch_size=}" ;;
            budget=*)      ef_budget="${tok#budget=}" ;;
            claimed=*)     ef_claimed="${tok#claimed=}" ;;
            completed=*)   ef_completed="${tok#completed=}" ;;
            filed=*)       ef_filed="${tok#filed=}" ;;
            commits=*)     ef_commits="${tok#commits=}" ;;
            plan_open=*)   ef_plan_open="${tok#plan_open=}" ;;
            plan_total=*)  ef_plan_total="${tok#plan_total=}" ;;
        esac
    done
    # Numeric fields must be integers or the rolling arithmetic downstream breaks;
    # coerce any non-numeric to 0 rather than write a poisoned record.
    for v in ef_batch_size ef_budget ef_claimed ef_completed ef_filed \
             ef_commits ef_plan_open ef_plan_total; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
    {
        ef_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '{"ts":"%s","host":"%s","batch_epic":"%s","batch_seed":"%s","batch_size":%s,"budget":%s,"claimed":%s,"completed":%s,"filed":%s,"commits":%s,"plan_open":%s,"plan_total":%s}\n' \
            "$ef_ts" "$ef_host" "$ef_epic" "$ef_seed" \
            "$ef_batch_size" "$ef_budget" "$ef_claimed" "$ef_completed" \
            "$ef_filed" "$ef_commits" "$ef_plan_open" "$ef_plan_total" \
            >>"$FLOW_LOG"
    } 2>/dev/null || true
    exit 0
fi

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

# ── flow (packet 682-epud) ───────────────────────────────────────────────────
# The ROLLING packets-per-cycle view over the flow log, answering the
# greedier-batching question (682-yiz7): does work-done-per-cycle rise faster
# than the fixed per-cycle cost as batches grow? overhead_ratio = total commits
# per total completed packet — the per-cycle overhead amortized across the work
# it produced. jq is the only parser (no python — tlatoani_hard_no_python); each
# line is parsed with `fromjson?` so a malformed row is dropped, never fatal.
flow_cycles=0
flow_avg_completed="-"; flow_avg_commits="-"; flow_overhead="-"
flow_source="absent"
if [ -r "$FLOW_LOG" ]; then
    flow_source="$FLOW_LOG"
    flow_stats="$(jq -R 'fromjson?' "$FLOW_LOG" 2>/dev/null | jq -s -r '
        map(select(type=="object")) as $r
        | ($r | length) as $n
        | if $n == 0 then "0 - - -"
          else
            ($r | map(.completed // 0) | add) as $c
          | ($r | map(.commits   // 0) | add) as $m
          | "\($n) " +
            "\(((($c/$n)*100)|round)/100) " +
            "\(((($m/$n)*100)|round)/100) " +
            "\(if $c > 0 then ((($m/$c)*100)|round)/100 else "-" end)"
          end' 2>/dev/null)"
    if [ -n "$flow_stats" ]; then
        read -r flow_cycles flow_avg_completed flow_avg_commits flow_overhead <<EOF
$flow_stats
EOF
    fi
fi
printf 'flow: cycles=%s avg_completed_per_cycle=%s avg_commits_per_cycle=%s overhead_ratio=%s source=%s\n' \
    "${flow_cycles:-0}" "${flow_avg_completed:--}" "${flow_avg_commits:--}" "${flow_overhead:--}" "$flow_source"

# ── timing (packet 682-emvg) ─────────────────────────────────────────────────
# WHERE does a cycle's wall-clock go? "time spent building, testing" is the most
# likely bottleneck and was invisible until the build/test/litmus entry points
# began appending one duration record per heavy step (via --emit-timing). This
# line reports the ROLLING view over that per-host log so a cycle can see which
# step to attack. jq is the only parser (no python — tlatoani_hard_no_python);
# each line is parsed with `fromjson?` so a malformed row is dropped, never fatal
# — fail-soft exactly like the flow: block above. The two named averages scope to
# distinct step namespaces so nested emitters cannot double-count:
#   build_check_ms_avg — step == "build-check"     (build.sh --check, the pre-push gate)
#   litmus_ms_avg      — step matches ^litmus       (run-litmus-test.sh suite)
# `slowest` is the single step:ms with the largest duration across ALL records —
# the one fact to look at first, in the spirit of the verdict line.
timing_steps=0
timing_build_check_avg="-"; timing_litmus_avg="-"; timing_slowest="-:-"
timing_source="absent"
if [ -r "$TIMING_LOG" ]; then
    timing_source="$TIMING_LOG"
    timing_stats="$(jq -R 'fromjson?' "$TIMING_LOG" 2>/dev/null | jq -s -r '
        map(select(type=="object")) as $r
        | ($r | length) as $n
        | if $n == 0 then "0 - - -:-"
          else
            ($r | map(select(.step=="build-check") | .duration_ms // 0)) as $bc
          | ($r | map(select((.step|tostring)|test("^litmus")) | .duration_ms // 0)) as $lm
          | ($r | max_by(.duration_ms // 0)) as $slow
          | "\($n) " +
            "\(if ($bc|length)>0 then (($bc|add)/($bc|length)|round) else "-" end) " +
            "\(if ($lm|length)>0 then (($lm|add)/($lm|length)|round) else "-" end) " +
            "\($slow.step // "-"):\($slow.duration_ms // 0)"
          end' 2>/dev/null)"
    if [ -n "$timing_stats" ]; then
        read -r timing_steps timing_build_check_avg timing_litmus_avg timing_slowest <<EOF
$timing_stats
EOF
    fi
fi
printf 'timing: steps=%s build_check_ms_avg=%s litmus_ms_avg=%s slowest=%s source=%s\n' \
    "${timing_steps:-0}" "${timing_build_check_avg:--}" "${timing_litmus_avg:--}" \
    "${timing_slowest:--:-}" "$timing_source"

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
