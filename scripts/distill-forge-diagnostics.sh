#!/usr/bin/env bash
# @trace spec:default-image, spec:forge-as-only-runtime
# distill-forge-diagnostics.sh — Summarize raw forge diagnostics into durable plan/ record.
#
# Reads the latest diagnostics log from target/forge-diagnostics/, extracts
# structured capability status, appends a dated summary to plan/diagnostics/,
# and identifies regressions vs the previous run.
#
# Usage:
#   scripts/distill-forge-diagnostics.sh
#   scripts/distill-forge-diagnostics.sh --latest <path>   # Explicit log file
#   scripts/distill-forge-diagnostics.sh --all             # Re-summarize all logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DIAGNOSTICS_DIR="target/forge-diagnostics"
PLAN_DIR="plan/diagnostics"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[distill]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[distill]${NC} $*"; }
_error() { echo -e "${RED}[distill]${NC} $*" >&2; }

LATEST_LOG=""
PROCESS_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            shift
            LATEST_LOG="${1:-}"
            ;;
        --all)
            PROCESS_ALL=true
            ;;
        --help|-h)
            echo "Usage: scripts/distill-forge-diagnostics.sh [--latest <path>] [--all]"
            exit 0
            ;;
        *) _error "Unknown flag: $1"; exit 2 ;;
    esac
    shift
done

mkdir -p "$DIAGNOSTICS_DIR" "$PLAN_DIR"

if [[ -z "$LATEST_LOG" && "$PROCESS_ALL" == false ]]; then
    LATEST_LOG=$(ls -t "$DIAGNOSTICS_DIR"/diagnostics_*.log 2>/dev/null | head -1)
fi

if [[ -z "$LATEST_LOG" ]]; then
    _warn "No diagnostics logs found in $DIAGNOSTICS_DIR"
    _info "Run the forge diagnostics litmus test first to generate one."
    exit 0
fi

distill_one() {
    local log_file="$1"
    local log_basename
    log_basename="$(basename "$log_file" .log)"
    local summary_file="$PLAN_DIR/${log_basename}-summary.md"

    if [[ ! -f "$log_file" ]]; then
        _error "Log file not found: $log_file"
        return 1
    fi

    _info "Distilling: $log_file"

    # Parse the JSON diagnostics output
    local timestamp=""
    local forge_version=""
    declare -A CAP_STATUS   # section.key -> OK|MISSING|ERROR
    local diagnostics_json=""

    if command -v python3 &>/dev/null; then
        diagnostics_json=$(python3 -c "
import json, sys, re
try:
    with open('$log_file') as f:
        content = f.read()
    # Extract JSON object (robust to markdown fences or command headers)
    match = re.search(r'\{.*\}', content, re.DOTALL)
    if match:
        data = json.loads(match.group(0))
    else:
        data = json.loads(content)
    # Flatten capabilities into section.key: status pairs
    caps = data.get('capabilities', {})
    for section, values in caps.items():
        if isinstance(values, dict):
            for key, val in values.items():
                status = 'OK'
                if not val or val in ('unset', 'N/A', 'BLOCKED', 'NOT_FOUND', 'NONE', 'NOT_FOUND'):
                    status = 'MISSING'
                print(f'{section}.{key}={status}')
        else:
            print(f'{section}={values}')
    # Diagnostics array
    diag = data.get('diagnostics', [])
    for d in diag:
        print(f'DIAGNOSTIC: {d}')
    # Actionable analysis (methodology response_shape) — these feed the
    # forge-enhancements/curated-toolchain-backlog packet.
    for t in data.get('missing_tools', []):
        print(f'MISSING_TOOL: {t}')
    for e in data.get('proposed_enhancements', []):
        if isinstance(e, dict):
            print(f'PROPOSED_ENHANCEMENT: {e.get(\"ecosystem\",\"other\")}: {e.get(\"tool\",\"?\")} — {e.get(\"why\",\"\")}')
        else:
            print(f'PROPOSED_ENHANCEMENT: {e}')
    for r in data.get('isolation_or_privacy_risks', []):
        print(f'ISOLATION_RISK: {r}')
    # Timestamp
    print(f'TIMESTAMP={data.get(\"diagnostics_timestamp\", \"unknown\")}')
    print(f'FORGE_VERSION={data.get(\"forge_version\", \"unknown\")}')
except Exception as e:
    print(f'PARSE_ERROR={e}')
" 2>&1) || diagnostics_json="PARSE_ERROR=Failed to parse JSON"

        # Brace-group + `|| true` to survive set -euo pipefail when the
        # python extractor emits only `PARSE_ERROR=…` (e.g. the raw log
        # is empty or malformed). Without this guard, an empty raw log
        # aborts distill_one before any summary is written — masking
        # the bug as "no summary appeared" instead of surfacing the
        # underlying empty-log finding.
        timestamp=$({ echo "$diagnostics_json" | grep '^TIMESTAMP=' || true; } | cut -d= -f2-)
        forge_version=$({ echo "$diagnostics_json" | grep '^FORGE_VERSION=' || true; } | cut -d= -f2-)
        timestamp=${timestamp:-unknown}
        forge_version=${forge_version:-unknown}
    else
        _warn "python3 not available; grep-based extraction"
        timestamp=$(grep -o '"diagnostics_timestamp":"[^"]*"' "$log_file" | head -1 | cut -d'"' -f4 || echo "unknown")
        forge_version=$(grep -o '"forge_version":"[^"]*"' "$log_file" | head -1 | cut -d'"' -f4 || echo "unknown")
        diagnostics_json=$(grep -oP '"(agent_available|network_isolation|hot_paths|environment|cache_routing|agent_instructions|shell|openspec|welcome|startup)"\s*:\s*\{[^}]*\}' "$log_file" 2>/dev/null || echo "PARSE_ERROR=grep fallback failed")
    fi

    # Compute metrics
    local ok_count=0
    local missing_count=0
    local parse_error=""

    while IFS= read -r line; do
        if [[ "$line" == PARSE_ERROR=* ]]; then
            parse_error="${line#PARSE_ERROR=}"
        elif [[ "$line" == *"=OK" ]]; then
            ok_count=$((ok_count + 1))
        elif [[ "$line" == *"=MISSING" ]]; then
            missing_count=$((missing_count + 1))
        fi
    done <<< "$diagnostics_json"

    local total_checks=$((ok_count + missing_count))
    local completeness_pct=0
    if [[ $total_checks -gt 0 ]]; then
        completeness_pct=$((ok_count * 100 / total_checks))
    fi

    # Compare with previous summary if available for regression detection
    local regression_note=""
    local prev_summary
    prev_summary=$(ls -t "$PLAN_DIR"/*-summary.md 2>/dev/null | head -2 | tail -1 || true)
    if [[ -n "$prev_summary" && -f "$prev_summary" ]]; then
        local prev_pct
        prev_pct=$(grep -o 'Completeness:[[:space:]]*[0-9]\+%' "$prev_summary" | grep -o '[0-9]\+' | head -1 || echo "0")
        if [[ -n "$prev_pct" && "$prev_pct" -gt "$completeness_pct" ]]; then
            regression_note="**REGRESSION**: Completeness dropped from ${prev_pct}% to ${completeness_pct}%"
        elif [[ -n "$prev_pct" && "$completeness_pct" -gt "$prev_pct" ]]; then
            regression_note="Improvement: completeness rose from ${prev_pct}% to ${completeness_pct}%"
        fi
    fi

    # Write summary
    cat > "$summary_file" <<SUMMARY
# Forge Diagnostics Summary — ${timestamp}

## Metadata

- **Source log**: \`${log_file}\`
- **Forge version**: ${forge_version}
- **Completeness**: ${ok_count} / ${total_checks} checks passed (${completeness_pct}%)
SUMMARY

    if [[ -n "$regression_note" ]]; then
        echo "" >> "$summary_file"
        echo "## Change vs Previous Run" >> "$summary_file"
        echo "" >> "$summary_file"
        echo "${regression_note}" >> "$summary_file"
    fi

    if [[ $missing_count -gt 0 ]]; then
        echo "" >> "$summary_file"
        echo "## Missing Capabilities" >> "$summary_file"
        echo "" >> "$summary_file"
        while IFS= read -r line; do
            if [[ "$line" == *"=MISSING" ]]; then
                local cap_name="${line%=MISSING}"
                echo "- \`${cap_name}\`" >> "$summary_file"
            fi
        done <<< "$diagnostics_json"
    fi

    if [[ -n "$parse_error" ]]; then
        echo "" >> "$summary_file"
        echo "## Parse Errors" >> "$summary_file"
        echo "" >> "$summary_file"
        echo "- ${parse_error}" >> "$summary_file"
    fi

    # Append actionable recommendations
    echo "" >> "$summary_file"
    echo "## Recommended Actions" >> "$summary_file"
    echo "" >> "$summary_file"

    while IFS= read -r line; do
        if [[ "$line" == *"=MISSING" ]]; then
            local cap="${line%=MISSING}"
            case "$cap" in
                "agent_available.claude")
                    echo "- Install claude-code in Containerfile (npm install -g @anthropic-ai/claude-code)" >> "$summary_file"
                    ;;
                "agent_available.codex")
                    echo "- Install codex in Containerfile (npm install -g @openai/codex)" >> "$summary_file"
                    ;;
                "network_isolation.external_curl")
                    echo "- Verify enclave network isolation: forge should not reach external internet directly" >> "$summary_file"
                    ;;
                "network_isolation.inference_reachable")
                    echo "- Ensure inference container is running and reachable on 'inference:11434'" >> "$summary_file"
                    ;;
                "hot_paths."*)
                    echo "- Verify tmpfs mount sizes in build_podman_args() for ${cap#hot_paths.}" >> "$summary_file"
                    ;;
                "cache_routing."*)
                    echo "- Ensure ${cap#cache_routing.} is exported in lib-common.sh" >> "$summary_file"
                    ;;
                "agent_instructions.paths")
                    echo "- Check that cache-discipline.md is properly mounted into ~/.config/opencode/instructions/" >> "$summary_file"
                    ;;
                "shell.tillandsias_help")
                    echo "- Ensure tillandsias-help shell function is sourced (check shell-helpers.sh)" >> "$summary_file"
                    ;;
                "openspec.opsx_bin")
                    echo "- Install openspec CLI in Containerfile" >> "$summary_file"
                    ;;
                *)
                    echo "- Investigate missing capability: ${cap}" >> "$summary_file"
                    ;;
            esac
        fi
    done <<< "$diagnostics_json"

    if [[ $missing_count -eq 0 ]]; then
        echo "- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt." >> "$summary_file"
    fi

    # Actionable analysis from the agent (methodology response_shape) — the
    # input the orchestrator triages into forge-enhancements/curated-toolchain-backlog.
    # `|| true`: grep exits non-zero on no-match, which would abort under
    # `set -e` when the array is empty (the common, healthy case).
    local risks
    risks=$(echo "$diagnostics_json" | grep '^ISOLATION_RISK: ' | sed 's/^ISOLATION_RISK: /- /' || true)
    if [[ -n "$risks" ]]; then
        echo "" >> "$summary_file"
        echo "## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)" >> "$summary_file"
        echo "" >> "$summary_file"
        echo "$risks" >> "$summary_file"
    fi

    local missing_tools enhancements
    missing_tools=$(echo "$diagnostics_json" | grep '^MISSING_TOOL: ' | sed 's/^MISSING_TOOL: /- /' || true)
    enhancements=$(echo "$diagnostics_json" | grep '^PROPOSED_ENHANCEMENT: ' | sed 's/^PROPOSED_ENHANCEMENT: /- /' || true)
    if [[ -n "$missing_tools" || -n "$enhancements" ]]; then
        echo "" >> "$summary_file"
        echo "## Forge Enhancement Candidates (→ curated-toolchain-backlog)" >> "$summary_file"
        echo "" >> "$summary_file"
        echo "Candidates only — orchestrator approves against the privacy/isolation gate." >> "$summary_file"
        echo "" >> "$summary_file"
        if [[ -n "$missing_tools" ]]; then
            echo "### Missing tools" >> "$summary_file"
            echo "$missing_tools" >> "$summary_file"
        fi
        if [[ -n "$enhancements" ]]; then
            echo "### Proposed enhancements" >> "$summary_file"
            echo "$enhancements" >> "$summary_file"
        fi
    fi

    # Launch-event stream forensics. The annex writes
    # `diagnostics_<UTC>.stderr.log` next to the stdout JSON; that file
    # carries the idiomatic-podman layer's `event:container_launch`
    # stream (ISO-8601 prefixed). Surfacing stages + states in the
    # distill summary gives the orchestrator the structural proof of
    # container-start health alongside the capability report — without
    # having to chase the raw log.
    #
    # @trace spec:runtime-diagnostics-stream, spec:podman-idiomatic-patterns
    local stderr_log="${log_file%.log}.stderr.log"
    if [[ -f "$stderr_log" && -s "$stderr_log" ]]; then
        local total_events running_events failed_events
        # `set -euo pipefail` is on at the top of this script — a grep
        # with no matches exits 1 and (via pipefail) would propagate up
        # through `local x=$(pipeline)` and abort the function. Wrap
        # each grep in a brace-group with `|| true` so a clean
        # no-match yields exactly "0" out of `wc -l`.
        total_events=$({ grep -E 'event:container_launch ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        running_events=$({ grep -E 'event:container_launch .* state=running ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        failed_events=$({ grep -E 'event:container_launch .* state=failed' "$stderr_log" 2>/dev/null || true; } | wc -l)
        # Trim possible leading whitespace from `wc` on some platforms.
        total_events=${total_events// /}
        running_events=${running_events// /}
        failed_events=${failed_events// /}

        # Distinct (stage, state) tuples — one line per unique pairing,
        # sorted for stable output. Surfaces "what reached running" at
        # a glance.
        local stage_state_table
        stage_state_table=$({ grep -oE 'event:container_launch stage=[^ ]+ state=[^ ]+' "$stderr_log" 2>/dev/null || true; } | sort -u)

        echo "" >> "$summary_file"
        echo "## Container-Start Stream (from .stderr.log companion)" >> "$summary_file"
        echo "" >> "$summary_file"
        echo "- **Source**: \`${stderr_log}\`" >> "$summary_file"
        echo "- **Total launch events**: ${total_events}" >> "$summary_file"
        echo "- **state=running**: ${running_events}" >> "$summary_file"
        echo "- **state=failed**: ${failed_events}" >> "$summary_file"
        if [[ -n "$stage_state_table" ]]; then
            echo "" >> "$summary_file"
            echo "### Distinct stage → state pairings" >> "$summary_file"
            echo "" >> "$summary_file"
            echo '```' >> "$summary_file"
            echo "$stage_state_table" >> "$summary_file"
            echo '```' >> "$summary_file"
        fi
        if [[ "$failed_events" -gt 0 ]]; then
            echo "" >> "$summary_file"
            echo "### ❌ Failed launches" >> "$summary_file"
            echo "" >> "$summary_file"
            echo '```' >> "$summary_file"
            grep -E 'event:container_launch .* state=failed' "$stderr_log" >> "$summary_file" 2>/dev/null || true
            echo '```' >> "$summary_file"
        fi

        # Typed-event arms beyond container_launch — added when the
        # gap-3 phase-2c+ wiring in tillandsias-headless lands real
        # spec-shape emissions. Surface counts always; sample lines
        # only when present (keeps the summary compact on a happy
        # session that produced no exits/signals/oom).
        #
        # @trace spec:runtime-diagnostics-stream (Container exit / signal /
        #   resource_exhaustion / stderr scenarios)
        # @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md
        #   (gap 3 phases 2c..2g)
        local exit_count signal_count resource_count stderr_count
        exit_count=$({ grep -E 'event:container_exit ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        signal_count=$({ grep -E 'event:container_signal ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        resource_count=$({ grep -E 'event:resource_exhaustion ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        stderr_count=$({ grep -E 'event:container_stderr ' "$stderr_log" 2>/dev/null || true; } | wc -l)
        exit_count=${exit_count// /}
        signal_count=${signal_count// /}
        resource_count=${resource_count// /}
        stderr_count=${stderr_count// /}

        if [[ "$exit_count" -gt 0 || "$signal_count" -gt 0 || "$resource_count" -gt 0 || "$stderr_count" -gt 0 ]]; then
            echo "" >> "$summary_file"
            echo "### Typed-event arms" >> "$summary_file"
            echo "" >> "$summary_file"
            echo "| event type | count |" >> "$summary_file"
            echo "|---|---:|" >> "$summary_file"
            [[ "$exit_count" -gt 0 ]]     && echo "| event:container_exit       | ${exit_count}     |" >> "$summary_file"
            [[ "$signal_count" -gt 0 ]]   && echo "| event:container_signal     | ${signal_count}   |" >> "$summary_file"
            [[ "$resource_count" -gt 0 ]] && echo "| event:resource_exhaustion  | ${resource_count} |" >> "$summary_file"
            [[ "$stderr_count" -gt 0 ]]   && echo "| event:container_stderr     | ${stderr_count}   |" >> "$summary_file"

            # Sample exit/signal/resource lines verbatim — these are
            # operationally meaningful (one or two lines each tells
            # the orchestrator exactly what died and why). Cap at 10
            # to keep the summary terse.
            if [[ "$exit_count" -gt 0 ]]; then
                echo "" >> "$summary_file"
                echo "#### container_exit lines (head 10)" >> "$summary_file"
                echo '```' >> "$summary_file"
                grep -E 'event:container_exit ' "$stderr_log" 2>/dev/null | head -10 >> "$summary_file" || true
                echo '```' >> "$summary_file"
            fi
            if [[ "$signal_count" -gt 0 ]]; then
                echo "" >> "$summary_file"
                echo "#### container_signal lines (head 10)" >> "$summary_file"
                echo '```' >> "$summary_file"
                grep -E 'event:container_signal ' "$stderr_log" 2>/dev/null | head -10 >> "$summary_file" || true
                echo '```' >> "$summary_file"
            fi
            if [[ "$resource_count" -gt 0 ]]; then
                echo "" >> "$summary_file"
                echo "#### resource_exhaustion lines (head 10)" >> "$summary_file"
                echo '```' >> "$summary_file"
                grep -E 'event:resource_exhaustion ' "$stderr_log" 2>/dev/null | head -10 >> "$summary_file" || true
                echo '```' >> "$summary_file"
            fi

            # Stderr is high-volume by design (every line from every
            # tailed support container). Just surface the top-N
            # noisiest containers + a short head-of-stream so the
            # orchestrator can spot which container is chattiest
            # without reading every line.
            if [[ "$stderr_count" -gt 0 ]]; then
                local stderr_by_container
                stderr_by_container=$({ grep -oE 'event:container_stderr container=[^ ]+' "$stderr_log" 2>/dev/null || true; } | sort | uniq -c | sort -rn | head -5)
                if [[ -n "$stderr_by_container" ]]; then
                    echo "" >> "$summary_file"
                    echo "#### container_stderr — top 5 containers by line count" >> "$summary_file"
                    echo '```' >> "$summary_file"
                    echo "$stderr_by_container" >> "$summary_file"
                    echo '```' >> "$summary_file"
                fi
            fi
        fi
    fi

    _info "Summary written: $summary_file"
    _info "Completeness: ${completeness_pct}% (${ok_count}/${total_checks})"
}

if [[ "$PROCESS_ALL" == true ]]; then
    for log in "$DIAGNOSTICS_DIR"/diagnostics_*.log; do
        [[ -f "$log" ]] && distill_one "$log"
    done
elif [[ -n "$LATEST_LOG" ]]; then
    distill_one "$LATEST_LOG"
fi

_info "Done. Summaries available in $PLAN_DIR/"
