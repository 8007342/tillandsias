#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:575, order:1001-q3zf
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
#   repeat:    window=<since=<utc>|3h> steps=<n> top3=<entries|-> source=<path|absent>
#   recur:     window=<n>d runs=<n> steps=<n> top3=<entries|-> source=<path|absent>
#   skippable: candidates=<n> floor_ms=<f> min_runs=<m> top3=<entries|-> source=<path|absent>
#
# THE repeat:/recur:/skippable: LINES (order 1001-q3zf). The operator
# asked, 2026-09-03, for "metrics to each host's iterations to detect repeated
# work that just wastes work every cycle, and expensive work that may be cached
# or skipped". The methodology (agent-observability.yaml, context_cost_metrics)
# had already DESIGNED a within-cycle step_repetition line that nothing
# emitted, and the timing log already held the answer: on macuahuitl one gate
# step (step:checking-the-plan-archiver-preserves-the-ready-set-831-ezea) had
# run 361 times at 13.9 s each, never once failing — 83 minutes bought exactly
# one bit of information. So these are REPORTERS over existing data. No new
# emitter, no new log.
#
#   repeat:    "which steps were paid REPEATEDLY inside THIS cycle?" Window is
#              `--cycle-start <utc>` / TILLANDSIAS_CYCLE_START_TS, else the last
#              3 h. top3 by COUNT desc then step asc, as <step>=<count>. Count,
#              not duration: a gate re-run after every rebase (982-cs43) costs
#              its duration TIMES the number of rounds; only the product is
#              actionable and duration is already on timing:.
#   recur:     "which steps are paid on EVERY cycle, and what do they cost
#              cumulatively?" Last N days (--recur-window-days, default 7). A
#              step recurs when it ran >= 2 times in the window. Entries are
#              <step>:runs=<n>:total_ms=<t>:avg_ms=<a>:fail_pct=<p>, top3 by
#              total_ms desc then step asc.
#   skippable: "which expensive, repeated, OUTCOME-INVARIANT steps could be
#              memoised or skipped?" Same window. A candidate ran >= min_runs
#              (default 5), averaged >= floor_ms (default 2000), and NEVER
#              changed outcome (fail_pct 0 or 100 — decided on raw counts, not
#              the rounded percentage). Entries are
#              <step>:runs=<n>:avg_ms=<a>:fail_pct=<p>:saved_ms_upper=<s>, top3
#              by saved_ms_upper desc then step asc.
#
# PARSE FROM THE RIGHT. Step names may contain colons (step:..., litmus:...,
# check:litmus-pre-build) — the same fact `slowest=<step>:<ms>` already lives
# with. The trailing :key=value fields never contain a colon, so the step is
# everything before the FIRST `:runs=` and the fields are read from the right.
# For that rule to hold, a step name that itself contains `:runs=` is
# rewritten to `_runs=` in the reported key (no emitter names steps that way;
# the rewrite keeps the rule true rather than documented). Pinned by a
# colon-bearing step name in scripts/test-cycle-metrics-recurrence.sh.
#
# STEP NAMES ARE SANITISED BEFORE THEY REACH A LINE. The grammar is
# whitespace- and comma-delimited, and the three lines are read back ONE PER
# LINE, so a control character, whitespace or comma inside a step name would
# shift the labels: a step whose JSON decoded to a newline put the recur:
# label on the tail of the repeat data and lost the skippable: line entirely
# (adversarial review, 2026-09-04; reachable through --emit-timing, which
# used to write the step unescaped). Every control, whitespace or comma byte
# in a reported step key becomes `_`, and an empty key becomes `-`;
# --emit-timing strips `"` and `\` from step/phase/host exactly as
# --emit-timing-batch always did, and turns raw control bytes into `_` so a
# newline in a step name cannot split the row. The timing log itself is not
# rewritten — the key is sanitised at report time.
#
# WINDOW LABELS NEVER HIDE A CALLER ERROR. A `--cycle-start` that does not
# parse (missing Z, garbage) reports `window=since=<value>:unparsed steps=0`
# rather than silently widening to 3h; fractional seconds are accepted on
# the flag as they are on records. A `--cycle-start` given as the LAST
# argument with no value is the env fallback, not the literal flag text.
# jq >= 1.7 is required for the windowing: 1.6 lacks strptime on Windows and
# applies the local UTC offset to fromdateiso8601. `now` is therefore bound
# through the same parser (now|todate|fromdateiso8601) so an offset cancels,
# and when the parser cannot round-trip the clock at all the three lines
# read `source=<path>:unwindowable` — zeros with a bare path would be a
# guess, and the litmus header names that as the failure it prevents.
#
# saved_ms_upper IS A BOUND, NOT A SAVING. It is total_ms - avg_ms: what a
# perfect skip could have saved if every run after the first had been
# redundant. The log carries no input identity, so this script cannot say a
# run WOULD have hit a cache — only that its outcome matched every other run.
# Anyone quoting it as a saving is making the claim this header refuses to
# make. The named next rung (not this order) is a tree digest on timing
# records, so exact repeats become measurable rather than bounded.
#
# WHAT THESE DO NOT CLAIM: they do not see cross-host caches, do not know why
# a step ran, and do not know whether a re-run was demanded by a rebase or by
# habit. They rank where to LOOK. All three read `source=absent` on a missing
# log and zeros on an empty window; never a guess.
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
# EMIT GRAMMAR (one record per cycle; never fails):
#   cycle-metrics.sh --emit-flow host=<h> cycle=<id> batch_epic=<id> \
#       batch_seed=<s> batch_size=<n> budget=<n> claimed=<n> completed=<n> \
#       filed=<n> commits=<n> plan_open=<n> plan_total=<n>
#   → {"ts":<utc>,"host":<h>,"cycle":<id>,"batch_epic":<id>,"batch_seed":<s>,
#      "batch_size":<n>,"budget":<n>,"claimed":<n>,"completed":<n>,"filed":<n>,
#      "commits":<n>,"plan_open":<n>,"plan_total":<n>}
#
# `cycle=` MAKES THE EMIT IDEMPOTENT and it is not optional in practice. A cycle
# that re-runs the emit -- because the gate failed and the finalization was
# retried, which is the normal shape of a bad cycle -- used to append a SECOND
# record. Measured: one cycle wrote three, and `cycles=8 overhead_ratio=2.25`
# was reporting six real cycles. The corruption is directional, not noise: the
# retried cycles are precisely the expensive ones, so duplicates inflate the
# cycle count with the worst cases while diluting avg_completed_per_cycle. The
# metric that the greedier-batching decision (682-yiz7) consumes was being
# skewed by the act of measuring it badly.
#
# With `cycle=<id>`, a second emit for the same host+cycle REPLACES the first.
# Replace rather than skip: a retry happens after MORE work, so its counts are
# the truthful ones.
#
# Without `cycle=`, the id is MINTED here as `<host>-<utc>` (order 801-tpxd)
# rather than written as the sentinel `-`. The old behaviour wrote `-` and
# warned; the warning did not stop two windows cycles from shipping a `-` row,
# and the attempt to repair one of them with a global sed clobbered a HISTORICAL
# record. The id was required from the caller yet fully derivable by the callee
# -- host + UTC is precisely what every cycle assembles by hand -- so deriving
# it removes the failure instead of narrating it. This is not the "silent
# heuristic" that was rightly refused before: bucketing by clock hour would have
# MERGED distinct cycles and dropped genuine records, whereas a second-resolution
# mint is injective over real cycles, so an unlabelled retry still appends
# exactly as it used to. The mint is announced on stderr as `note:`.
#
# Exit status is 0 whenever the report was produced. A metrics reporter that
# fails the cycle it is measuring is a metric that can take down what it
# measures; the VERDICT carries the judgement instead.

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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Where a metrics log lives when the caller has not named one (order 890-t9pu).
#
# `/tmp` WAS the default, and `/tmp` IS NOT ONE PLACE. On a Windows host
# `./build.sh` re-execs into WSL2 and writes there, while `cycle-metrics.sh`
# runs in Git Bash and reads a different filesystem entirely. MEASURED on
# yolanda 2026-08-25: 322 `build-check` records on the WSL side, 0 on the Git
# Bash side, so `timing:` reported `build_check_ms_avg=-` while 322
# measurements sat in a log the reader could not open, and named a `slowest`
# step from a two-day-old file. Every timing metric that host ever published
# was stale or absent — including, until it was found, the measurement of the
# boundary itself.
#
# The checkout is the one thing both userlands agree on, so the default moves
# under `target/` (gitignored, already the home for build artifacts). Callers
# that name a log explicitly are untouched, which keeps every fixture working.
#
# ONE-TIME COST, stated rather than hidden: a host with history in `/tmp` starts
# a fresh series here. The rolling views degrade gracefully — they report
# `source=absent` until the first append — so this costs recent averages, not
# correctness. That is the price of the numbers being attributable at all.
#
# Falls back to `/tmp` when there is no writable checkout to write into, so a
# forge or a bare invocation outside a repo keeps working exactly as before.
# The rule itself lives in one file so a writer and a reader cannot drift apart
# — which is the defect this fixes. Sourced best-effort: if it is unavailable
# the old /tmp behaviour is preserved rather than the script failing.
# shellcheck source=scripts/metrics-log-path.sh
. "$SCRIPT_DIR/metrics-log-path.sh" 2>/dev/null || true
command -v metrics_default_log >/dev/null 2>&1 || {
    metrics_default_log() { printf '/tmp/%s' "$1"; }
}
_metrics_default_log() { metrics_default_log "$1" "$REPO_ROOT"; }

USAGE_LOG="${TILLANDSIAS_EXPERT_USAGE_LOG:-$(_metrics_default_log forge-expert-usage.jsonl)}"
FLOW_LOG="${TILLANDSIAS_CYCLE_FLOW_LOG:-$(_metrics_default_log tillandsias-cycle-flow.jsonl)}"
TIMING_LOG="${TILLANDSIAS_TIMING_LOG:-$(_metrics_default_log tillandsias-timing.jsonl)}"

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
    # A `"` or `\` in a string field would make the row malformed JSON (dropped
    # by every reader) or, worse, a well-formed row whose step DECODES to a
    # control character and shifts the report's line labels (1001-q3zf review).
    # Strip them, exactly as --emit-timing-batch does with gsub(/["\\]/, "").
    # A raw control byte (a newline in the step) would split the row and lose
    # the measurement, so it becomes `_` — the report-time sanitiser's rule.
    # An empty step (`step=`) is recorded as absent, `-`, not as "".
    et_host="${et_host//[\"\\]/}"; et_step="${et_step//[\"\\]/}"; et_phase="${et_phase//[\"\\]/}"
    et_host="${et_host//[[:cntrl:]]/_}"; et_step="${et_step//[[:cntrl:]]/_}"; et_phase="${et_phase//[[:cntrl:]]/_}"
    [ -n "$et_step" ] || et_step="-"
    {
        et_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '{"ts":"%s","host":"%s","step":"%s","phase":"%s","duration_ms":%s,"exit":%s}\n' \
            "$et_ts" "$et_host" "$et_step" "$et_phase" \
            "$et_duration_ms" "$et_exit" \
            >>"$TIMING_LOG"
    } 2>/dev/null || true
    exit 0
fi

# ── --emit-context: append one CONTEXT-GROWTH PROXY record ───────────────────
# OPERATOR DIRECTIVE 2026-09-03 (become token-conscious), methodology
# agent_observability_protocol.cycle_metrics.context_cost_metrics.
#
# THESE ARE PROXIES AND THE FIELD NAMES SAY SO. `transcript_bytes` is BYTES of
# the harness transcript, not tokens. The bytes-per-token ratio is model- and
# content-dependent and this project does NOT assume one; a caller converting
# this to a token estimate must cite the measurement that established the
# conversion. A proxy reported as a token count is the defect the whole
# observability protocol exists to prevent.
#
# Best-effort by construction, exactly like --emit-timing and --emit-flow: a
# metrics write may never fail the cycle it measures. Always exits 0. An absent
# transcript is recorded as 0, which the reporter renders `absent` — never
# guessed, never omitted.
if [ "${1:-}" = "--emit-context" ]; then
    shift
    ec_host="-"; ec_cycle="-"; ec_transcript="-"
    ec_bytes=0; ec_lines=0; ec_tools=0; ec_compactions=0
    for tok in "$@"; do
        case "$tok" in
            host=*)        ec_host="${tok#host=}" ;;
            cycle=*)       ec_cycle="${tok#cycle=}" ;;
            transcript=*)  ec_transcript="${tok#transcript=}" ;;
            tools=*)       ec_tools="${tok#tools=}" ;;
            compactions=*) ec_compactions="${tok#compactions=}" ;;
        esac
    done
    # Measure the transcript here rather than trusting a passed-in number: the
    # caller reporting its own size is a self-report, and a self-report is an
    # instrument (993-yqie / the 2026-09-03 session's most repeated lesson).
    if [ -f "$ec_transcript" ]; then
        ec_bytes="$(wc -c <"$ec_transcript" 2>/dev/null | tr -d ' ')"
        ec_lines="$(wc -l <"$ec_transcript" 2>/dev/null | tr -d ' ')"
    fi
    for v in ec_bytes ec_lines ec_tools ec_compactions; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
    {
        ec_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf '{"ts":"%s","host":"%s","cycle":"%s","transcript_bytes":%s,"transcript_lines":%s,"tool_calls":%s,"compactions":%s}\n' \
            "$ec_ts" "$ec_host" "$ec_cycle" \
            "$ec_bytes" "$ec_lines" "$ec_tools" "$ec_compactions" \
            >>"${TILLANDSIAS_CONTEXT_LOG:-${TMPDIR:-/tmp}/tillandsias-context.jsonl}"
    } 2>/dev/null || true
    exit 0
fi

# ── --emit-timing-batch: append MANY duration records in ONE spawn (765-dfry)
# stdin lines, tab-separated: step<TAB>phase<TAB>duration_ms<TAB>exit<TAB>host
# Rationale: each spawn of this script costs ~10-20ms; a --check run closes
# ~45 phases, so per-record emission would tax the gate ~0.7s to measure 6ms
# guards — the audit's empty-suite-floor lesson applied to telemetry itself.
# One spawn amortizes the whole gate. Same grammar and best-effort contract as
# --emit-timing; the 693-tf79 day bound applies per line; malformed lines are
# skipped, never written poisoned. Always exits 0.
if [ "${1:-}" = "--emit-timing-batch" ]; then
    {
        etb_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        awk -F'\t' -v ts="$etb_ts" '
            NF >= 3 && $1 != "" {
                step = $1; phase = $2; dur = $3; ec = $4; host = $5
                if (dur !~ /^[0-9]+$/) dur = 0
                if (dur + 0 >= 86400000) next
                if (ec !~ /^[0-9]+$/) ec = 0
                if (phase == "") phase = "-"
                if (host == "") host = "-"
                gsub(/["\\]/, "", step); gsub(/["\\]/, "", phase); gsub(/["\\]/, "", host)
                printf "{\"ts\":\"%s\",\"host\":\"%s\",\"step\":\"%s\",\"phase\":\"%s\",\"duration_ms\":%d,\"exit\":%d}\n", \
                    ts, host, step, phase, dur, ec
            }' >>"$TIMING_LOG"
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
    ef_host="-"; ef_epic="-"; ef_seed="-"; ef_cycle=""
    ef_batch_size=0; ef_budget=0; ef_claimed=0; ef_completed=0; ef_filed=0
    ef_commits=0; ef_plan_open=0; ef_plan_total=0
    for tok in "$@"; do
        case "$tok" in
            host=*)        ef_host="${tok#host=}" ;;
            cycle=*)       ef_cycle="${tok#cycle=}" ;;
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
    # MINT the cycle id when the caller omitted it (order 801-tpxd). The old
    # behaviour wrote `"cycle":"-"` and warned; two windows cycles then shipped
    # a `-` row, and one of them "repaired" it with a global sed that clobbered
    # a HISTORICAL record. Both failures trace to the same root: the id was
    # required from the caller but derivable by the callee. Host + UTC timestamp
    # is exactly what every cycle constructs by hand, so construct it here and
    # the omission stops being able to produce a poisoned row at all.
    #
    # `-` is now unreachable by construction, which is the pinned property
    # (test-cycle-flow-emit-idempotency.sh scenarios 5 and 8): a sentinel that
    # cannot be written cannot be mistaken for a cycle id, and the replace-key
    # (host+cycle) can no longer collapse every unlabelled cycle onto one row.
    #
    # Minted ids are second-resolution, so a genuine retry (which happens
    # seconds-to-minutes later) mints a NEW id and APPENDS — preserving the old
    # no-cycle= behaviour for the case the caller really is unlabelled — while a
    # caller that passes cycle= keeps full replace-on-retry idempotency. Passing
    # cycle= is still the right thing; it is simply no longer load-bearing for
    # the log's integrity.
    if [ -z "$ef_cycle" ]; then
        ef_mint_host="$ef_host"
        case "$ef_mint_host" in '' | '-') ef_mint_host="unknown-host" ;; esac
        ef_cycle="${ef_mint_host}-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
        echo "note: --emit-flow without cycle=<id>; minted cycle=$ef_cycle from host+UTC (order 801-tpxd). Pass cycle=<id> for replace-on-retry idempotency (682-epud)." >&2
    fi
    # Defence in depth: a caller that passes the literal sentinel gets it
    # rewritten too, so no path reaches the record printf with `-`.
    if [ "$ef_cycle" = "-" ]; then
        ef_cycle="unlabelled-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
        echo "note: --emit-flow cycle=- is not a cycle id; minted cycle=$ef_cycle (order 801-tpxd)." >&2
    fi
    {
        ef_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        record="$(printf '{"ts":"%s","host":"%s","cycle":"%s","batch_epic":"%s","batch_seed":"%s","batch_size":%s,"budget":%s,"claimed":%s,"completed":%s,"filed":%s,"commits":%s,"plan_open":%s,"plan_total":%s}' \
            "$ef_ts" "$ef_host" "$ef_cycle" "$ef_epic" "$ef_seed" \
            "$ef_batch_size" "$ef_budget" "$ef_claimed" "$ef_completed" \
            "$ef_filed" "$ef_commits" "$ef_plan_open" "$ef_plan_total")"
        # Replace-if-present, keyed on host+cycle. Rewrite via a temp file and
        # mv so an interrupted emit cannot truncate the log it is correcting.
        if [ "$ef_cycle" != "-" ] && [ -f "$FLOW_LOG" ] \
           && grep -q "\"host\":\"${ef_host}\",\"cycle\":\"${ef_cycle}\"" "$FLOW_LOG"; then
            tmp="${FLOW_LOG}.$$"
            # `|| true` is load-bearing: when the log holds ONLY the record
            # being replaced, grep -v emits nothing and exits 1, which used to
            # abandon the && chain and leave the stale record in place -- the
            # emit reporting success while replacing nothing. The fixture's
            # scenario 2 is that exact case.
            { grep -v "\"host\":\"${ef_host}\",\"cycle\":\"${ef_cycle}\"" "$FLOW_LOG" || true; } > "$tmp"
            printf '%s\n' "$record" >> "$tmp" && mv -f "$tmp" "$FLOW_LOG"
            rm -f "$tmp"
        else
            printf '%s\n' "$record" >> "$FLOW_LOG"
        fi
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
# Order 1001-q3zf: the repeat:/recur:/skippable: knobs. Each flag has an env
# fallback so a host that exports its Start-Of-Cycle once need not thread it
# through every call; the flag wins when both are given.
CYCLE_START_TS="${TILLANDSIAS_CYCLE_START_TS:-}"
RECUR_WINDOW_DAYS="${TILLANDSIAS_RECUR_WINDOW_DAYS:-7}"
SKIP_MIN_RUNS="${TILLANDSIAS_SKIP_MIN_RUNS:-5}"
SKIP_FLOOR_MS="${TILLANDSIAS_SKIP_FLOOR_MS:-2000}"
while [ $# -gt 0 ]; do
    case "$1" in
        --experts-only) EXPERTS_ONLY=true ;;
        --cycle-start) if [ $# -gt 1 ]; then shift; CYCLE_START_TS="$1"; fi ;;
        --cycle-start=*) CYCLE_START_TS="${1#--cycle-start=}" ;;
        --recur-window-days) if [ $# -gt 1 ]; then shift; RECUR_WINDOW_DAYS="$1"; fi ;;
        --recur-window-days=*) RECUR_WINDOW_DAYS="${1#--recur-window-days=}" ;;
        *) [ -z "$SINCE_REF" ] && SINCE_REF="$1" ;;
    esac
    shift
done
# Non-numeric knobs fall back to their defaults rather than aborting the jq
# program (which would silently zero all three lines under 2>/dev/null).
# Values are then NORMALISED (leading zeros dropped, more than nine digits
# is the default) so the label echoes the number used, not the flag text:
# `--recur-window-days 07` printed `window=07d` before this.
case "$RECUR_WINDOW_DAYS" in ''|*[!0-9]*|??????????*) RECUR_WINDOW_DAYS=7 ;; esac
case "$SKIP_MIN_RUNS" in ''|*[!0-9]*|??????????*) SKIP_MIN_RUNS=5 ;; esac
case "$SKIP_FLOOR_MS" in ''|*[!0-9]*|??????????*) SKIP_FLOOR_MS=2000 ;; esac
RECUR_WINDOW_DAYS=$((10#$RECUR_WINDOW_DAYS))
SKIP_MIN_RUNS=$((10#$SKIP_MIN_RUNS))
SKIP_FLOOR_MS=$((10#$SKIP_FLOOR_MS))

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
    PLAN_STREAM="$( { grep -v '"server":"' "$USAGE_LOG"; grep '"server":"forge-plan"' "$USAGE_LOG"; grep '"server":"cli"' "$USAGE_LOG"; } 2>/dev/null )"
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
    t=$(printf '%s\n' "$PLAN_STREAM" | "$JQ" -r '.tool // empty' 2>/dev/null | sort -u | paste -sd, - 2>/dev/null || true)
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
# ── expert health (packet 737-zcj5) ──────────────────────────────────────────
# CALL VOLUME CANNOT SEE AN OUTAGE. A server that is DOWN writes no usage rows,
# and neither does a server nobody called — both render as absence in every
# count above. `health=` is the field that separates them, sourced from
# scripts/check-mcp-expert-health.sh's JSONL rather than from usage at all.
#   health=ok           every expected expert answered its last probe
#   health=ok-unexposed the servers answered, but the CYCLE reported the tools
#                       were absent from its own tool surface (order 801-m9tk)
#   health=down:<csv>   named experts failed their last probe (the outage)
#   health=absent       no expected expert is registered in this environment
#   health=unprobed     the probe has not run here; NOT the same as healthy
# Keeping `unprobed` distinct from `ok` matters: reporting an unmeasured expert
# as healthy is the order-531 shape (truthful `experts: ready`, every answer
# unsupported) this line exists to prevent.
#
# `ok-unexposed` is the SAME LESSON one level up (order 801-m9tk). For three
# consecutive windows cycles the probe printed ok:experts-healthy while no
# mcp__forge-plan__* / mcp__project-info__* tool was bound to the session at
# all, so every read fell back to the binary and this line said `health=ok`
# throughout. The handshake and the agent's tool surface are different facts;
# the probe can only measure the first, and a script cannot observe the second
# from a subprocess. So the cycle ATTESTS the surface
# (scripts/check-mcp-surface.sh attest exposed|unexposed) and this line carries
# the join. Absence of an attestation reads `ok` exactly as before — the value
# only appears when a cycle explicitly reported an unexposed surface, so no host
# is retro-labelled by a fact nobody recorded. An `ok-unexposed` cycle also
# fires the mcp_outage: line, because a read path that silently degraded for a
# whole cycle IS the outage 737-zcj5 was built to stop losing.
HEALTH_LOG="${TILLANDSIAS_EXPERT_HEALTH_LOG:-$(_metrics_default_log forge-expert-health.jsonl)}"
mcp_health="unprobed"
mcp_outages=0
if [ -s "$HEALTH_LOG" ]; then
    # Last state wins per server; count every non-up record for the outage line.
    mcp_health="$(awk -F'"' '
        /"server":/ {
            srv=""; st="";
            for (i = 1; i <= NF; i++) {
                if ($i == "server") srv = $(i + 2);
                if ($i == "state")  st  = $(i + 2);
            }
            if (srv != "" && st != "") last[srv] = st;
        }
        END {
            down = ""; absent = 0; total = 0;
            for (s in last) {
                total++;
                if (last[s] == "down") down = down (down == "" ? "" : ",") s;
                else if (last[s] == "absent") absent++;
            }
            if (total == 0) { print "unprobed" }
            else if (down != "") { print "down:" down }
            else if (absent == total) { print "absent" }
            else { print "ok" }
        }' "$HEALTH_LOG" 2>/dev/null)"
    [ -n "$mcp_health" ] || mcp_health="unprobed"
    mcp_outages="$(grep -c '"state":"\(down\|absent\)"' "$HEALTH_LOG" 2>/dev/null)" || mcp_outages=0
fi

# ── surface join (order 801-m9tk) ────────────────────────────────────────────
# Only ever REFINES `ok` into `ok-unexposed`; never rescues a `down`, never
# invents a state for a cycle that attested nothing. The attestation is read
# through the same freshness rule check-mcp-surface.sh applies, so a previous
# cycle's marker cannot label this one.
if [ "$mcp_health" = "ok" ]; then
    _surface_stamp="${TILLANDSIAS_MCP_SURFACE_STAMP:-$(git rev-parse --absolute-git-dir 2>/dev/null || echo "$REPO_ROOT/.git")/tillandsias-mcp-surface}"
    if [ -f "$_surface_stamp" ]; then
        # Space-split + anchored, not `\b` (order 803-bqte): BSD sed has no
        # `\b`, so on macOS both reads returned empty and the `mcp:` line
        # silently dropped the surface attestation it is supposed to fold in.
        _sfc_claim="$(tr ' ' '\n' < "$_surface_stamp" 2>/dev/null | sed -n 's/^claim=\(.*\)$/\1/p' | head -1)"
        _sfc_epoch="$(tr ' ' '\n' < "$_surface_stamp" 2>/dev/null | sed -n 's/^epoch=\([0-9]*\)$/\1/p' | head -1)"
        _sfc_now="$(date -u +%s 2>/dev/null || echo 0)"
        _sfc_max="${TILLANDSIAS_MCP_SURFACE_MAX_AGE:-14400}"
        _sfc_fresh=1
        case "$_sfc_epoch" in
            '' | *[!0-9]*) : ;;
            *) [ $((_sfc_now - _sfc_epoch)) -gt "$_sfc_max" ] && _sfc_fresh=0 ;;
        esac
        if [ "$_sfc_fresh" = "1" ] && [ "$_sfc_claim" = "unexposed" ]; then
            mcp_health="ok-unexposed"
            # A degraded read path for a whole cycle is an outage record even
            # though no server ever reported `down`.
            mcp_outages=$((mcp_outages + 1))
        fi
    fi
fi

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
    printf 'mcp: servers=%s per_server=%s legacy_untagged=%s health=%s source=%s\n' \
        "$mcp_servers" "$per_server" "$legacy_untagged" "$mcp_health" "$source_state"
else
    mcp_servers=0
    if [ "$tools" != "-" ]; then
        mcp_servers=$(printf '%s' "$tools" | tr ',' '\n' | grep -c .)
    fi
    printf 'mcp: servers=%s plan-expert-calls=%s other-servers=uninstrumented-see-682-m8ek health=%s source=%s\n' \
        "$mcp_servers" "$calls" "$mcp_health" "$source_state"
fi

# NEGATIVE CONTROL (packet 737-zcj5, exit criterion 3). This line is emitted
# ONLY when a probe actually recorded a non-up state. A healthy cycle prints
# nothing here, because a signal that fires every cycle is one nobody reads —
# this milestone's own recurring failure. When it does fire it carries the
# ledger trace: the handoff pastes cycle-metrics verbatim, and the loop-status
# entry is built from the handoff, so the outage reaches the plan without any
# agent choosing to write it down.
if [ "${mcp_outages:-0}" -gt 0 ] 2>/dev/null; then
    printf 'mcp_outage: records=%s health=%s log=%s action=record-and-continue-see-737-zcj5\n' \
        "$mcp_outages" "$mcp_health" "$HEALTH_LOG"
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
# Order 721-nyev: resolve by EXECUTION. The old loop trusted the executable
# bit, which on a shared Windows/WSL checkout picks the Linux ELF over the
# runnable .exe -- this line reported plan_bin=absent on a host where the
# binary was present and working.
. "$REPO_ROOT/scripts/plan-binary-probe.sh"
GRADE_BIN="$(cd "$REPO_ROOT" && resolve_plan_binary || true)"
accuracy_line='expert_accuracy: deferred source=litmus:expert-groundtruth-harness'
# Order 786-kjke: grade EVERY committed query set, not just rung1.
#
# This line used to run bare `grade --root .`, which defaults to rung1 and
# reported `pass=22 total=22 rate=100% source=groundtruth-rung1`. That was
# TRUE but its scope was undisclosed: six further graded cases in two
# fixture-backed sets were never in the number. Widening was impossible before
# now — globbing the directory graded those sets against the live ledger and
# produced six FALSE reds — and is safe now that each set declares its own
# corpus. A missing corpus is exit 2, which yields no result line and leaves
# the `deferred` fallback in place, so this cannot silently under-report.
#
# GRADE EXACTLY ONCE (found during the 1001-q3zf review, 2026-09-04). This
# used to read `( timeout 60 grade ... || grade ... )`, meant as "use timeout
# when the host has it". But grade exits 1 whenever a CASE fails, so on any
# host with a red groundtruth case the `||` re-ran the whole grade: measured
# 5.3 s once, 10.7 s inside the reporter, and every litmus step that calls
# `--experts-only` under a 10 s budget was killed (exit 124) from
# 2026-09-02T21Z, when two spec.answer cases first went red. The choice of
# timeout-or-bare is made BEFORE the call now, so a red case costs one grade.
if [ -n "$GRADE_BIN" ]; then
    gt_sets="$REPO_ROOT/openspec/litmus-tests/groundtruth"
    gr=""
    if command -v timeout >/dev/null 2>&1; then grade_wrap="timeout"; else grade_wrap=""; fi
    if [ -d "$gt_sets" ]; then
        # shellcheck disable=SC2086
        gr="$(cd "$REPO_ROOT" && ( if [ -n "$grade_wrap" ]; then timeout 60 "$GRADE_BIN" grade --root . openspec/litmus-tests/groundtruth/*.yaml; else "$GRADE_BIN" grade --root . openspec/litmus-tests/groundtruth/*.yaml; fi ) 2>/dev/null | grep '^groundtruth-result:' | tail -1)"
    fi
    if [ -z "$gr" ]; then
        gr="$(cd "$REPO_ROOT" && ( if [ -n "$grade_wrap" ]; then timeout 30 "$GRADE_BIN" grade --root .; else "$GRADE_BIN" grade --root .; fi ) 2>/dev/null | grep '^groundtruth-result:' | tail -1)"
        gsrc="groundtruth-rung1"
    else
        gsrc="groundtruth-all-sets"
    fi
    if [ -n "$gr" ]; then
        gp="$(printf '%s' "$gr" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
        gt="$(printf '%s' "$gr" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
        # ORDER 888-miiy. `total` now includes cases the host could not GRADE
        # (no embedding endpoint -> spec.answer skipped). Two things follow, and
        # getting either wrong is worse than the bug this replaced:
        #
        #   RATE IS OVER GRADED CASES, NOT TOTAL. pass/total on an endpoint-less
        #   host reads 28/33 = 84% and looks exactly like a 16-point accuracy
        #   REGRESSION, when nothing regressed and five cases simply did not run.
        #   A metric that moves when nothing changed is one people learn to
        #   ignore.
        #
        #   SKIPPED IS REPORTED, ALWAYS. This line is what every handoff pastes
        #   and what a release reads, so it is where "the expert tier was not
        #   exercised here" has to become visible. Silence would make an
        #   ungraded tier indistinguishable from a passing one — the exact
        #   failure this milestone exists to kill.
        gs="$(printf '%s' "$gr" | sed -n 's/.*skipped=\([0-9]*\).*/\1/p')"
        [ -n "$gs" ] || gs=0
        gse="$(printf '%s' "$gr" | sed -n 's/.*skipped_engines=\([^ ]*\).*/\1/p')"
        if [ -n "$gp" ] && [ -n "$gt" ] && [ "$gt" -gt 0 ]; then
            graded=$(( gt - gs ))
            if [ "$graded" -gt 0 ]; then
                accuracy_line="expert_accuracy: pass=${gp} graded=${graded} total=${gt} rate=$(( gp * 100 / graded ))% source=${gsrc}"
            else
                # Nothing was graded at all. Never render that as a rate.
                accuracy_line="expert_accuracy: pass=0 graded=0 total=${gt} rate=n/a source=${gsrc}"
            fi
            if [ "$gs" -gt 0 ]; then
                accuracy_line="${accuracy_line} skipped=${gs}${gse:+ skipped_engines=${gse}} NOT-EXERCISED-ON-THIS-HOST"
            fi
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
    flow_stats="$("$JQ" -R 'fromjson?' "$FLOW_LOG" 2>/dev/null | "$JQ" -s -r '
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
#   build_check_ms_avg — step == "build-check"     (build.sh --check, the local gate)
#   litmus_ms_avg      — step matches ^litmus       (run-litmus-test.sh suite)
# `slowest` is the single step:ms with the largest duration across ALL records —
# the one fact to look at first, in the spirit of the verdict line.
#
# PROVENANCE (785-ibu9). A `step:` record's duration is the named step's OWN
# measured work (the time inside build.sh's `_run`), which is what makes it
# safe to attribute. A phase that runs no measurable command instead carries
# `phase: "build-span"` and its duration is banner-to-banner wall clock, which
# may include work the named step did not do; `slowest=` marks those `~span`.
# Read an unmarked name as "this step costs this much" and a `~span` name as
# "this much wall clock elapsed around here". The distinction exists because a
# span was once read as a step cost and a packet was filed on the inflated
# number (783-xyk5's context, corrected in its own ledger events).
timing_steps=0
timing_build_check_avg="-"; timing_litmus_avg="-"; timing_slowest="-:-"
timing_source="absent"
if [ -r "$TIMING_LOG" ]; then
    timing_source="$TIMING_LOG"
    timing_stats="$("$JQ" -R 'fromjson?' "$TIMING_LOG" 2>/dev/null | "$JQ" -s -r '
        # 693-tf79: reject implausible durations (negative, or >= 24h in ms).
        # A record whose duration_ms is really an absolute epoch (~1.78e12,
        # from a zero start time) must never enter the averages or the slowest
        # pick. This is defense-in-depth for logs written before the source
        # guard in timing-log.sh; the source now skips such records entirely.
        map(select(type=="object"
              and (.duration_ms | type)=="number"
              and .duration_ms >= 0
              and .duration_ms < 86400000)) as $r
        | ($r | length) as $n
        | if $n == 0 then "0 - - -:-"
          else
            ($r | map(select(.step=="build-check") | .duration_ms // 0)) as $bc
          # 765-dfry: scoped EXACTLY to the suite aggregate — per-test records
          # are `litmus:<name>` and would otherwise pollute this average with
          # a different grain (the old ^litmus prefix matched both).
          | ($r | map(select(.step=="litmus-suite") | .duration_ms // 0)) as $lm
          # 765-dfry: slowest prefers the FINEST grain. Aggregate records
          # (build-check, build-preamble, litmus-suite, local-ci-phase-*)
          # contain their own sub-steps, so they always out-size them and the
          # line would forever name an unattackable total. When per-step
          # records exist (step:/check:/litmus:), pick slowest among those;
          # fall back to all records otherwise (pre-765 logs keep working).
          | ($r | map(select((.step|tostring)|test("^(step:|check:|litmus:)")))) as $fine
          | ((if ($fine|length) > 0 then $fine else $r end) | max_by(.duration_ms // 0)) as $slow
          # 785-ibu9: a build-span record is banner-to-banner wall clock, not
          # the cost of the named step alone, so it can bundle work that step
          # never did. Suffix it ~span so the one number a reader looks at
          # first cannot be mistaken for an attributable step cost — a wrong
          # attribution is what got a packet filed on an inflated reading.
          # (No apostrophes in this block: it lives inside a single-quoted jq
          # program, where one would terminate the string.)
          | (if ($slow.phase // "") == "build-span" then "~span" else "" end) as $prov
          # 890-nkdz rule 1 (FORCED-ONLY for cross-host gate timings): a memoised
          # run (step build-check-memoized, ~0.4s ok:gate-fresh) never enters the
          # mean above, but a log that CONTAINS memoised runs is a mixed log, and
          # a host quoting build_check_ms_avg from it must say so at emission,
          # not trust a reader to know. Fifth field: memoised count; sixth: forced.
          | ($r | map(select(.step=="build-check-memoized")) | length) as $memo
          | "\($n) " +
            "\(if ($bc|length)>0 then (($bc|add)/($bc|length)|round) else "-" end) " +
            "\(if ($lm|length)>0 then (($lm|add)/($lm|length)|round) else "-" end) " +
            "\($slow.step // "-")\($prov):\($slow.duration_ms // 0) " +
            "\($memo) \($bc|length)"
          end' 2>/dev/null)"
    if [ -n "$timing_stats" ]; then
        read -r timing_steps timing_build_check_avg timing_litmus_avg timing_slowest timing_memo timing_forced <<EOF
$timing_stats
EOF
    fi
fi
# 890-nkdz: the mixed/forced label is ABSENT only when every contributing run
# was forced (no memoised record in the log); present otherwise, naming both
# counts so a cross-host comparison can be restricted to forced runs.
timing_mix=""
if [ "${timing_memo:-0}" -gt 0 ] 2>/dev/null; then
    timing_mix=" build_check_mix=mixed:forced=${timing_forced:-0},memoised=${timing_memo}"
fi
printf 'timing: steps=%s build_check_ms_avg=%s%s litmus_ms_avg=%s slowest=%s source=%s\n' \
    "${timing_steps:-0}" "${timing_build_check_avg:--}" "$timing_mix" "${timing_litmus_avg:--}" \
    "${timing_slowest:--:-}" "$timing_source"

if [ "$EXPERTS_ONLY" = true ]; then
    exit 0
fi

# ── repeat / recur / skippable (order 1001-q3zf) ────────────────────────────
# Three views over the SAME timing log the block above reads, answering the
# operator's ask of 2026-09-03: "detect repeated work that just wastes work
# every cycle, and expensive work that may be cached or skipped". The data was
# already there — 48,790 records on macuahuitl when this was written — and only
# the reporter was missing.
#   repeat:    which steps were paid more than once INSIDE THIS CYCLE (the
#              methodology step_repetition line; count, not duration, because
#              a gate re-run after every rebase costs duration TIMES rounds).
#   recur:     which steps are paid on EVERY cycle, and what they cost
#              cumulatively over the window (total_ms, not avg — the product
#              is what is actionable).
#   skippable: which expensive, repeated, OUTCOME-INVARIANT steps are
#              memoisation/skip candidates: every run after the first bought no
#              information, because the outcome never changed. Invariance is
#              decided on the raw counts (fails == 0 or fails == runs), never on
#              the rounded fail_pct, so one failure in three hundred runs is not
#              rounded into "never fails".
#
# ONE extra pass over the log (a single jq process; the whole thing measured
# 0.4 s over 48,790 rows). Records are windowed by `ts`: a row whose ts does
# not parse as %Y-%m-%dT%H:%M:%SZ (the emitters write `unknown` when date(1)
# fails) cannot be placed in time and is dropped from THESE lines only; the
# timing: line above still counts it. Malformed rows drop via fromjson?
# exactly as above. The clock is jq's `now` — no date(1), so the same program
# runs on BSD userland and Git Bash, given jq >= 1.7 (see the header: 1.6 is
# offset-shifted or strptime-less, and the lines say `:unwindowable` rather
# than print zeros when the parser cannot round-trip the clock).
#
# PARSE FROM THE RIGHT. Step names contain colons (`step:checking-...`,
# `litmus:<name>`, `check:litmus-pre-build`) — the same situation `slowest=` already
# lives with. So in every top3 entry the trailing `:key=value` fields never
# contain a colon and the step is everything before the FIRST `:runs=`.
#
# saved_ms_upper IS AN UPPER BOUND, and every surface that quotes it must say
# so. It is total_ms minus one run: the most a perfect skip could have saved.
# The log carries no input identity, so this line cannot say a given run WOULD
# have hit a cache — only that its outcome was the same as the last one. The
# named next rung, deliberately not this packet, is a tree digest on timing
# records so exact repeats become measurable rather than bounded.
#
# The window for repeat: is `--cycle-start <utc>` (or TILLANDSIAS_CYCLE_START_TS),
# else the last three hours; for recur:/skippable: the last N days
# (--recur-window-days, default 7). An empty window reports zeros with
# source=<path>; a missing or unreadable log (a directory, say) reports zeros
# with source=absent; a log jq could not read reports source=<path>:unreadable.
# Never a guess.
recur_source="absent"; recur_input=/dev/null
if [ -f "$TIMING_LOG" ] && [ -r "$TIMING_LOG" ]; then
    recur_source="$TIMING_LOG"; recur_input="$TIMING_LOG"
fi
recur_stats="$("$JQ" -n -R -r --arg cs "$CYCLE_START_TS" --arg rdays "$RECUR_WINDOW_DAYS" \
    --arg minruns "$SKIP_MIN_RUNS" --arg floor "$SKIP_FLOOR_MS" '
    # (No apostrophes in this block: it lives inside a single-quoted jq
    # program, where one would terminate the string.)
    # The clock is bound THROUGH the parser: on jq 1.6 fromdateiso8601 applies
    # the local UTC offset, and binding now the same way cancels it; on a jq
    # whose strptime is missing the round-trip yields null and the first
    # output line says so instead of letting zeros pose as an empty window.
    ((now | todate | fromdateiso8601?) // null) as $now
    | (if $now == null then "clock=unwindowable" else "clock=ok" end),
    ( [inputs | fromjson?]
    | map(select(type=="object"
          and (.duration_ms | type)=="number"
          and .duration_ms >= 0
          and .duration_ms < 86400000))
    # Step keys are sanitised here, before they can reach the -r output: a
    # control character would split the three lines, whitespace or a comma
    # would split an entry. Colons are kept (parse from the right).
    # An empty step becomes "-" (a bare `=5` entry is legal but unreadable),
    # and a literal `:runs=` inside a step name is rewritten so the
    # parse-from-the-right rule (step = everything before the FIRST `:runs=`)
    # holds for every key this program can emit.
    | map(. + {t: ((.ts | tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null),
               s: ((.step // "-") | tostring | gsub("[[:cntrl:][:space:],]"; "_")
                   | gsub(":runs="; "_runs=") | if . == "" then "-" else . end)})
    | map(select(.t != null)) as $r
    | ($cs | gsub("[[:cntrl:][:space:],]"; "_")) as $cslabel
    | ($cs | if . == "" then null
             else ((sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null) end) as $cstart
    # A --cycle-start that fails to parse on a clock that ALSO fails to
    # round-trip is a platform limitation, not a caller error; the source
    # suffix (:unwindowable) carries that diagnosis and the label stays bare.
    | ($cs != "" and $cstart == null and $now != null) as $unparsed
    | (if $cstart == null then (($now // 0) - 10800) else $cstart end) as $rstart
    | (if $cs == "" then "3h"
       elif $unparsed then "since=\($cslabel):unparsed"
       else "since=\($cslabel)" end) as $rwin
    | (($now // 0) - ($rdays | tonumber) * 86400) as $wstart
    | ($r | (if $unparsed then [] else map(select(.t >= $rstart)) end) | group_by(.s)
         | map({s: .[0].s, n: length}) | sort_by([-.n, .s])) as $rep
    | ($r | map(select(.t >= $wstart))) as $rw
    | ($rw | group_by(.s)
         | map({s: .[0].s, runs: length,
                total: (map(.duration_ms) | add | floor),
                fails: (map(select(((.exit // 0) | tostring) != "0")) | length)})
         | map(. + {avg: ((.total / .runs) | floor),
                    fail_pct: ((.fails * 100 / .runs) | round)})) as $agg
    | ($agg | map(select(.runs >= 2)) | sort_by([-.total, .s])) as $rec
    | ($agg | map(select(.runs >= ($minruns | tonumber)
                         and .avg >= ($floor | tonumber)
                         and (.fails == 0 or .fails == .runs)))
            | map(. + {saved: (.total - .avg)}) | sort_by([-.saved, .s])) as $skip
    | "window=\($rwin) steps=\($rep | length) top3=" +
        (if ($rep | length) == 0 then "-"
         else ($rep[:3] | map("\(.s)=\(.n)") | join(",")) end),
      "window=\($rdays)d runs=\($rw | length) steps=\($rec | length) top3=" +
        (if ($rec | length) == 0 then "-"
         else ($rec[:3] | map("\(.s):runs=\(.runs):total_ms=\(.total):avg_ms=\(.avg):fail_pct=\(.fail_pct)") | join(",")) end),
      "candidates=\($skip | length) floor_ms=\($floor) min_runs=\($minruns) top3=" +
        (if ($skip | length) == 0 then "-"
         else ($skip[:3] | map("\(.s):runs=\(.runs):avg_ms=\(.avg):fail_pct=\(.fail_pct):saved_ms_upper=\(.saved)") | join(",")) end)
    )' "$recur_input" 2>/dev/null)"
recur_clock=""; repeat_line=""; recur_line=""; skip_line=""
if [ -n "$recur_stats" ]; then
    { IFS= read -r recur_clock; IFS= read -r repeat_line; IFS= read -r recur_line; IFS= read -r skip_line; } <<EOF
$recur_stats
EOF
elif [ "$recur_source" != "absent" ]; then
    # The log exists and is readable but jq produced nothing (jq missing or
    # too old to run the program). Say so; zeros with a bare path would be a
    # guess dressed as an empty window.
    recur_source="${recur_source}:unreadable"
fi
case "$recur_clock" in
    clock=unwindowable) [ "$recur_source" != "absent" ] && recur_source="${recur_source}:unwindowable" ;;
esac
if [ -z "$repeat_line" ]; then
    # Same sanitiser as the jq path (control, whitespace, comma -> `_`), so
    # one --cycle-start renders one label whether or not jq ran. No
    # `:unparsed` here: without jq nobody parsed it, and the source suffix
    # (`:unreadable`) already says why.
    if [ -n "$CYCLE_START_TS" ]; then
        repeat_line="window=since=${CYCLE_START_TS//[[:cntrl:][:space:],]/_} steps=0 top3=-"
    else repeat_line="window=3h steps=0 top3=-"; fi
fi
printf 'repeat: %s source=%s\n' "$repeat_line" "$recur_source"
printf 'recur: %s source=%s\n' \
    "${recur_line:-window=${RECUR_WINDOW_DAYS}d runs=0 steps=0 top3=-}" "$recur_source"
printf 'skippable: %s source=%s\n' \
    "${skip_line:-candidates=0 floor_ms=${SKIP_FLOOR_MS} min_runs=${SKIP_MIN_RUNS} top3=-}" "$recur_source"

# ── plan ────────────────────────────────────────────────────────────────────
packets="-"; ready="-"; blocked="-"; pending="-"
PLAN_BIN=""
# Order 721-nyev: resolve by EXECUTION. The old loop trusted the executable
# bit, which on a shared Windows/WSL checkout picks the Linux ELF over the
# runnable .exe -- this line reported plan_bin=absent on a host where the
# binary was present and working.
. "$REPO_ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(cd "$REPO_ROOT" && resolve_plan_binary || true)"
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
    # --first-parent, deliberately (order 769-aqpc). On a platform branch the
    # cycle's own work is the first-parent chain; a pre-push `git merge
    # origin/linux-next` pulls in dozens of sibling commits that are NOT this
    # cycle's output. Measured 2026-08-16 on windows: the plain count reported
    # 24 where the cycle had made 3 commits + 1 merge — and this number feeds
    # `--emit-flow commits=`, so the inflation skewed overhead_ratio (the
    # greedier-batching decision input, 682-yiz7) by 6x for every cycle that
    # merged. The merge commit itself still counts: making it was cycle work.
    commits="$(git -C "$REPO_ROOT" rev-list --count --first-parent "${SINCE_REF}..HEAD" 2>/dev/null || echo -)"
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
elif [ "$calls" -gt 0 ] && [ "$graded" -gt 0 ] && [ "$answered" -eq 0 ]; then
    # The order-531 signature: the expert ran every time and answered nothing.
    #
    # ORDER 902-j49y — `calls > 0` IS LOAD-BEARING AND WAS MISSING. `graded`
    # comes from the groundtruth harness; `answered` comes from the usage log.
    # Two independent sources, and the guard for a claim about one was read
    # from the other. With an empty usage log — a fresh host, a rotated log —
    # `answered` is 0 while `graded` is whatever the harness scored, so this
    # arm fired and reported the order-531 signature ("the ARTIFACT is wrong,
    # check the base branch") about an expert that was demonstrably fine.
    #
    # MEASURED on yolanda 2026-08-26, immediately after 890-t9pu rotated the
    # usage log to a path both userlands can read: `expert_accuracy: pass=28
    # graded=28 rate=100%` on the same line as
    # `verdict: attention:expert-answered-nothing-check-base-branch`. A 100%
    # accuracy score and "answered nothing" cannot both be true.
    #
    # "the expert ran every time and answered nothing" is FALSE when it never
    # ran. That state has its own arm directly below — which was unreachable
    # whenever the harness had graded anything, i.e. exactly when the report
    # was most likely to be read.
    verdict="attention:expert-answered-nothing-check-base-branch"
elif [ "$calls" -eq 0 ]; then
    verdict="attention:experts-never-called"
fi
printf 'verdict: %s\n' "$verdict"
exit 0
