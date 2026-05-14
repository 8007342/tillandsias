#!/usr/bin/env bash
# @trace spec:observability-convergence, spec:versioning, spec:spec-traceability
#
# Render the repo-visible CentiColon dashboard from the append-only signature log.
# The Markdown view is for GitHub; the JSON view is for agents and automation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${SOURCE:-$REPO_ROOT/target/convergence/centicolon-signature.jsonl}"
DOC_DIR="$REPO_ROOT/docs/convergence"
TARGET_DIR="$REPO_ROOT/target/convergence"
MD_OUT="${MD_OUT:-$DOC_DIR/centicolon-dashboard.md}"
JSON_OUT="${JSON_OUT:-$DOC_DIR/centicolon-dashboard.json}"
SUMMARY_OUT="${SUMMARY_OUT:-$TARGET_DIR/summary.md}"
# Latest resource sample emitted by tillandsias-metrics (Wave 13 Gap #3).
# Schema: { "cpu_percent": f64, "memory_percent": f64, "disk_percent": f64, "sample_timestamp": iso8601 }
# @trace spec:resource-metric-collection, spec:observability-metrics
# @cheatsheet observability/cheatsheet-metrics.md
METRICS_SAMPLE="${METRICS_SAMPLE:-$TARGET_DIR/resource-metrics.json}"
TITLE="${TITLE:-Progression Trends}"
SERIES_NAMESPACE="${SERIES_NAMESPACE:-local_development}"
SERIES_LABEL="${SERIES_LABEL:-Local Development}"
EMPTY_HINT="${EMPTY_HINT:-Run ./build.sh --ci-full after the signature writer is active to populate history.}"
TERMINAL_PREVIEW="${TERMINAL_PREVIEW:-1}"
TREND_CHUNK_WIDTH="${TREND_CHUNK_WIDTH:-32}"

mkdir -p "$DOC_DIR" "$TARGET_DIR"

spark_glyph() {
    awk -v value="${1:-0}" 'BEGIN {
        if (value == "" || value != value) { print "·"; exit }
        if (value < 12.5) print "▁";
        else if (value < 25) print "▂";
        else if (value < 37.5) print "▃";
        else if (value < 50) print "▄";
        else if (value < 62.5) print "▅";
        else if (value < 75) print "▆";
        else if (value < 87.5) print "▇";
        else print "█";
    }'
}

if [[ -s "$SOURCE" ]]; then
    mapfile -t rows < <(
        jq -r '
          . as $r
          | ($r.release_version // $r.version // "unknown") as $release
          | ($r.release_date // ($r.timestamp | tostring | split("T")[0]) // "unknown") as $date
          | ($r.source_commit // "unknown") as $commit
          | (($r.expected_total_cc // $r.project_cc_total // 0) | tonumber) as $total
          | (($r.actual_earned_cc // $r.project_cc_earned // 0) | tonumber) as $earned
          | (($r.residual_cc // ($total - $earned)) | tonumber) as $residual
          | (if $total > 0 then (($earned / $total) * 100) else 0 end) as $pct
          | (($r.max_residual_spec // $r.top_residual_spec // ($r.top_project_residuals[0].spec_or_obligation_id // "n/a")) | tostring) as $worst_spec
          | (($r.max_residual_reason // ($r.top_residual_reasons[0].reason // ($r.top_project_residuals[0].reason // "n/a"))) | tostring) as $worst_reason
          | (($r.evidence_bundle_ref // $r.evidence_bundle_hash // "n/a") | tostring) as $evidence
          | (($r.centicolon_projection_ref // $r.centicolon_projection_branch // "n/a") | tostring) as $projection
          | (($r.ci_result // "n/a") | tostring) as $ci_result
          | (($r.ci_run_id // "n/a") | tostring) as $ci_run_id
          | [
              $release, $date, $commit, ($total|tostring), ($earned|tostring),
              ($residual|tostring), ($pct|tostring), $worst_spec, $worst_reason,
              $evidence, $projection, $ci_result, $ci_run_id
            ]
          | @tsv
        ' "$SOURCE"
    )
else
    rows=()
fi

sparkline=""
residualline=""
history_json='[]'
latest_json='{}'
history_markdown_rows=""
trend_windows_markdown=""
trend_windows_json='[]'
latest_release="none"
latest_pct="0"
latest_pct_display="0.0"
latest_residual="0"
latest_reason="n/a"
latest_spec="n/a"
latest_ci="n/a"
latest_commit="n/a"
json_lines_file="$(mktemp)"
trend_windows_json_file="$(mktemp)"
trap 'rm -f "$json_lines_file" "$trend_windows_json_file"' EXIT

window_index=0
window_count=0
window_closed=""
window_residual=""
window_start_release=""
window_start_commit=""
window_end_release=""
window_end_commit=""

append_trend_window() {
    local kind="$1"
    local glyphs="$2"
    local residuals="$3"
    local start_release="$4"
    local start_commit="$5"
    local end_release="$6"
    local end_commit="$7"
    local count="$8"

    [[ -z "$glyphs" ]] && return 0

    window_index=$((window_index + 1))
    jq -nc \
        --arg kind "$kind" \
        --argjson index "$window_index" \
        --arg start_release "$start_release" \
        --arg start_commit "$start_commit" \
        --arg end_release "$end_release" \
        --arg end_commit "$end_commit" \
        --argjson count "$count" \
        --arg closed "$glyphs" \
        --arg residual "$residuals" \
        '{
          index:$index,
          kind:$kind,
          start_release:$start_release,
          start_commit:$start_commit,
          end_release:$end_release,
          end_commit:$end_commit,
          count:$count,
          closed:$closed,
          residual:$residual
        }' >>"$trend_windows_json_file"

    printf -v trend_windows_markdown '%s%s\n' \
        "$trend_windows_markdown" \
        "$glyphs"
}

total_rows="${#rows[@]}"
if [[ "$total_rows" -gt 0 ]]; then
    printf '[dashboard] rendering %d signature records for %s\n' "$total_rows" "$SERIES_LABEL" >&2
fi

row_index=0
for row in "${rows[@]}"; do
    row_index=$((row_index + 1))
    IFS=$'\t' read -r release date commit total earned residual pct worst_spec worst_reason evidence projection ci_result ci_run_id <<<"$row"
    glyph="$(spark_glyph "$pct")"
    pct_display="$(printf '%.1f' "$pct")"
    inverse="$(awk -v value="${pct:-0}" 'BEGIN {
        if (value == "" || value != value) { print "·"; exit }
        residual = 100 - value;
        if (residual < 12.5) print "▁";
        else if (residual < 25) print "▂";
        else if (residual < 37.5) print "▃";
        else if (residual < 50) print "▄";
        else if (residual < 62.5) print "▅";
        else if (residual < 75) print "▆";
        else if (residual < 87.5) print "▇";
        else print "█";
    }')"
    sparkline+="$glyph"
    residualline+="$inverse"
    jq -nc \
        --arg release "$release" \
        --arg date "$date" \
        --arg commit "$commit" \
        --argjson total "${total:-0}" \
        --argjson earned "${earned:-0}" \
        --argjson residual "${residual:-0}" \
        --argjson pct "${pct:-0}" \
        --arg worst_spec "$worst_spec" \
        --arg worst_reason "$worst_reason" \
        --arg evidence "$evidence" \
        --arg projection "$projection" \
        --arg ci_result "$ci_result" \
        --arg ci_run_id "$ci_run_id" \
        '{release:$release,date:$date,commit:$commit,total_cc:$total,earned_cc:$earned,residual_cc:$residual,percent_closed:$pct,worst_spec:$worst_spec,worst_reason:$worst_reason,evidence:$evidence,projection:$projection,ci_result:$ci_result,ci_run_id:$ci_run_id,trend_glyph:""}' \
        >>"$json_lines_file"
    printf -v row_line '| `%s` | `%s` | `%s/%s` | `%s` | `%s%%` | `%s` | `%s` | `%s` |' \
        "$release" "$commit" "$earned" "$total" "$residual" "$pct_display" "$glyph" "$worst_spec" "$worst_reason"
    history_markdown_rows+="${row_line}"$'\n'
    latest_release="$release"
    latest_pct="$pct"
    latest_pct_display="$pct_display"
    latest_residual="$residual"
    latest_reason="$worst_reason"
    latest_spec="$worst_spec"
    latest_ci="$ci_result"
    latest_commit="$commit"

    if [[ -z "$window_start_release" ]]; then
        window_start_release="$release"
        window_start_commit="$commit"
    fi
    window_end_release="$release"
    window_end_commit="$commit"
    window_closed+="$glyph"
    window_residual+="$inverse"
    window_count=$((window_count + 1))
    if (( row_index % TREND_CHUNK_WIDTH == 0 )); then
        append_trend_window "closed" "$window_closed" "$window_residual" \
            "$window_start_release" "$window_start_commit" "$window_end_release" "$window_end_commit" \
            "$window_count"
        window_closed=""
        window_residual=""
        window_start_release=""
        window_start_commit=""
        window_end_release=""
        window_end_commit=""
        window_count=0
    fi

    if (( row_index == 1 || row_index % 50 == 0 || row_index == total_rows )); then
        printf '[dashboard] processed %d/%d rows for %s\n' "$row_index" "$total_rows" "$SERIES_LABEL" >&2
    fi
done

if [[ -n "$window_closed" ]]; then
    append_trend_window "closed" "$window_closed" "$window_residual" \
        "$window_start_release" "$window_start_commit" "$window_end_release" "$window_end_commit" \
        "$window_count"
fi

if [[ "${#rows[@]}" -gt 0 ]]; then
    history_json="$(jq -s '.' "$json_lines_file")"
    latest_json="$(jq '.[-1]' <<<"$history_json")"
    trend_windows_json="$(jq -s '.' "$trend_windows_json_file")"
else
    history_json='[]'
    latest_json='{}'
    trend_windows_json='[]'
fi

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record_count="${#rows[@]}"

# Compute trend metrics from history rows for alert thresholds.
# pass_rate_7d: percentage of CI_PASS records over the last 7 rows.
# coverage_avg_7d: average percent_closed over the last 7 rows.
# Both inputs use the most recent rows because release cadence is irregular
# and a fixed time window can be empty for days at a time.
if [[ "$record_count" -gt 0 ]]; then
    pass_rate_7d=$(jq '.[-7:] | (map(select(.ci_result == "PASS")) | length) / length * 100' <<<"$history_json")
    coverage_avg_7d=$(jq '.[-7:] | map(.percent_closed) | add / length' <<<"$history_json")
else
    pass_rate_7d="null"
    coverage_avg_7d="null"
fi

# Alert thresholds defined in plan/CLAUDE.md: red < 90, yellow < 95.
alert_red_threshold=90
alert_yellow_threshold=95

# Compute alert level from the most recent percent_closed.
if [[ "$record_count" -gt 0 ]]; then
    latest_alert=$(jq -nc \
        --argjson pct "${latest_pct:-0}" \
        --argjson red "$alert_red_threshold" \
        --argjson yellow "$alert_yellow_threshold" \
        '
          if $pct < $red then "red"
          elif $pct < $yellow then "yellow"
          else "green"
          end
        ')
else
    latest_alert='"unknown"'
fi

# Wave 13 Gap #3: include latest resource-metric sample if the sampler has
# written one. The sampler (tillandsias-metrics) emits a small JSON blob to
# $METRICS_SAMPLE on each cycle. Absent file => zeroed defaults so the
# downstream JSON schema is stable for consumers.
# @trace spec:resource-metric-collection, spec:observability-metrics
if [[ -s "$METRICS_SAMPLE" ]]; then
    metrics_block_json=$(jq -c '{
        cpu_percent: (.cpu_percent // 0.0),
        memory_percent: (.memory_percent // 0.0),
        disk_percent: (.disk_percent // 0.0),
        sample_timestamp: (.sample_timestamp // "1970-01-01T00:00:00Z"),
        source: "tillandsias-metrics::DashboardSnapshot"
    }' "$METRICS_SAMPLE" 2>/dev/null || printf '%s' '{"cpu_percent":0.0,"memory_percent":0.0,"disk_percent":0.0,"sample_timestamp":"1970-01-01T00:00:00Z","source":"tillandsias-metrics::DashboardSnapshot"}')
else
    metrics_block_json='{"cpu_percent":0.0,"memory_percent":0.0,"disk_percent":0.0,"sample_timestamp":"1970-01-01T00:00:00Z","source":"tillandsias-metrics::DashboardSnapshot"}'
fi

dashboard_contract_json=$(cat <<'CONTRACT'
{
  "signature_format": {
    "description": "Each CentiColon signature record is an append-only entry in target/convergence/centicolon-signature.jsonl. The dashboard projects these into the .md and .json artefacts below.",
    "fields": [
      "release_version (semver)",
      "release_date (UTC ISO 8601)",
      "source_commit (git sha)",
      "expected_total_cc (integer)",
      "actual_earned_cc (integer)",
      "residual_cc (integer)",
      "max_residual_spec (spec id)",
      "max_residual_reason (string)",
      "evidence_bundle_ref (path or hash)",
      "ci_result (PASS|FAIL)"
    ]
  },
  "refresh_policy": {
    "cadence": "Local CI may regenerate after every metrics-producing run. Main-branch merges should append a new signature and refresh the dashboard. Releases publish dashboard + signature log + delta + evidence bundle together.",
    "staleness_threshold_hours": 24,
    "stale_marker": "If generated_at is older than staleness_threshold_hours from now, downstream readers SHOULD treat the snapshot as stale and refuse to use it as authoritative."
  },
  "alert_thresholds": {
    "red_below_percent_closed": 90,
    "yellow_below_percent_closed": 95,
    "rationale": "Red signals the implementation has drifted materially from spec; yellow signals an emerging gap; green confirms the residual cc budget is within acceptable bounds."
  },
  "integration": {
    "source_of_truth": "openspec/specs/knowledge-source-of-truth/spec.md",
    "interpretation": "This dashboard is a read-only projection of the evidence semantics defined by knowledge-source-of-truth. The dashboard MUST NOT be hand-edited. To change what is reported, change the upstream signature log, the renderer (scripts/update-convergence-dashboard.sh), or the methodology files (methodology/proximity.yaml, methodology/litmus-centicolon-wiring.yaml).",
    "spec_traceability": "openspec/specs/spec-traceability/spec.md",
    "observability_convergence": "openspec/specs/observability-convergence/spec.md",
    "methodology_accountability": "openspec/specs/methodology-accountability/spec.md"
  },
  "trend_metrics": {
    "pass_rate_7d_description": "Percentage of the most recent 7 signature records whose ci_result is PASS.",
    "coverage_avg_7d_description": "Average percent_closed across the most recent 7 signature records."
  }
}
CONTRACT
)

cat >"$JSON_OUT" <<EOF
{
  "generated_at": "$generated_at",
  "title": "$TITLE",
  "series_namespace": "$SERIES_NAMESPACE",
  "series_label": "$SERIES_LABEL",
  "source_file": "$(printf '%s' "$SOURCE" | sed "s#^$REPO_ROOT/##")",
  "record_count": $record_count,
  "sparkline_closed": "$sparkline",
  "sparkline_residual": "$residualline",
  "alert_level": $latest_alert,
  "alert_thresholds": {
    "red_below_percent_closed": $alert_red_threshold,
    "yellow_below_percent_closed": $alert_yellow_threshold
  },
  "trend_metrics": {
    "pass_rate_7d_percent": $pass_rate_7d,
    "coverage_avg_7d_percent": $coverage_avg_7d
  },
  "metrics": $metrics_block_json,
  "dashboard_contract": $dashboard_contract_json,
  "trend_windows": $trend_windows_json,
  "latest": $latest_json,
  "history": $history_json
}
EOF

# Render the markdown dashboard. The narrative sections (Reading Guide, Signature
# Format, Refresh Policy, Alert Thresholds, Integration) cite the source-of-truth
# spec and stay stable across regenerations.
# @trace spec:observability-convergence, spec:knowledge-source-of-truth
{
    printf '<!-- @trace spec:observability-convergence, spec:knowledge-source-of-truth -->\n'
    printf '<!-- THIS FILE IS AUTO-GENERATED by scripts/update-convergence-dashboard.sh — DO NOT EDIT. -->\n\n'
    printf '# %s\n\n' "$TITLE"

    printf '_Generated at %s for series `%s` (`%s`)._\n\n' \
        "$generated_at" "$SERIES_LABEL" "$SERIES_NAMESPACE"

    if [[ "$record_count" -gt 0 ]]; then
        printf '_Source: `%s` · %d signature records · latest release `%s` at commit `%s`._\n\n' \
            "$(printf '%s' "$SOURCE" | sed "s#^$REPO_ROOT/##")" \
            "$record_count" "$latest_release" "$latest_commit"
    else
        printf '_No signature records yet. %s_\n\n' "$EMPTY_HINT"
    fi

    printf '## Trend Sparklines\n\n'
    printf 'Each glyph below represents one signature record. The top strip is closed cc (taller = more closed); the residual strip below it is the inverse.\n\n'
    printf '```text\n'
    if [[ "$record_count" -gt 0 ]]; then
        printf '%b' "$trend_windows_markdown"
    fi
    printf '```\n\n'

    if [[ "$record_count" -gt 0 ]]; then
        printf '## Latest Signature\n\n'
        printf '| Field | Value |\n|---|---|\n'
        printf '| Release | `%s` |\n' "$latest_release"
        printf '| Commit | `%s` |\n' "$latest_commit"
        printf '| Closed | `%s%%` |\n' "$latest_pct_display"
        printf '| Residual cc | `%s` |\n' "$latest_residual"
        printf '| Worst spec | `%s` |\n' "$latest_spec"
        printf '| Worst reason | `%s` |\n' "$latest_reason"
        printf '| CI result | `%s` |\n' "$latest_ci"
        latest_alert_unquoted=$(printf '%s' "$latest_alert" | tr -d '"')
        printf '| Alert level | `%s` (red < %d%%, yellow < %d%%) |\n\n' \
            "$latest_alert_unquoted" "$alert_red_threshold" "$alert_yellow_threshold"
    fi

    printf '## Signature Format\n\n'
    printf 'Each row in the dashboard projects one record from `target/convergence/centicolon-signature.jsonl`. A signature record is the (metrics + timestamp + evidence-bundle hash) tuple defined by `methodology/proximity.yaml` and `methodology/litmus-centicolon-wiring.yaml`:\n\n'
    printf '%s\n' '- `release_version` — semver string identifying the release the snapshot belongs to.'
    printf '%s\n' '- `release_date` — UTC ISO 8601 timestamp of when the snapshot was produced.'
    printf '%s\n' '- `source_commit` — git sha that produced the snapshot.'
    printf '%s\n' '- `expected_total_cc`, `actual_earned_cc`, `residual_cc` — CentiColon budget, what the evidence earned, and what remains unclosed.'
    printf '%s\n' '- `max_residual_spec`, `max_residual_reason` — the spec id and reason carrying the largest remaining residual.'
    printf '%s\n' '- `evidence_bundle_ref` — path or hash of the evidence bundle (`target/convergence/evidence-bundle.json`) that backs the signature.'
    printf '%s\n\n' '- `ci_result` — PASS / FAIL of the CI run that produced the snapshot.'

    printf '## Refresh Policy\n\n'
    printf 'The dashboard is regenerated from the signature log every time `%s` runs (typically after a metrics-producing CI cycle).\n\n' "$(basename "$0")"
    printf '%s\n' '- Local CI may regenerate after any metrics-producing run.'
    printf '%s\n' '- Main-branch merges SHOULD append a new signature and refresh the dashboard.'
    printf '%s\n' '- Release runs SHOULD publish dashboard + signature log + delta + evidence bundle together.'
    printf '%s\n\n' '- The `generated_at` timestamp at the top of this file is the staleness signal. If it is older than 24 hours, downstream consumers SHOULD treat the snapshot as stale.'

    printf '## Alert Thresholds\n\n'
    printf '| Level | Trigger | Meaning |\n|---|---|---|\n'
    printf '| `red` | `percent_closed < %d%%` | Implementation has drifted materially from spec; investigate immediately. |\n' "$alert_red_threshold"
    printf '| `yellow` | `percent_closed < %d%%` | Emerging gap; review residual cc and worst-spec reason. |\n' "$alert_yellow_threshold"
    printf '| `green` | otherwise | Residual cc within acceptable bounds. |\n\n'

    printf '## Integration & Interpretation\n\n'
    printf 'This dashboard is a **read-only projection** of the evidence semantics defined by `openspec/specs/knowledge-source-of-truth/spec.md`. The dashboard MUST NOT be hand-edited. To change what is reported:\n\n'
    printf '%s\n' '- Change the upstream signature log (`target/convergence/centicolon-signature.jsonl`), or'
    printf '%s\n' '- Change the renderer (`scripts/update-convergence-dashboard.sh`), or'
    printf '%s\n\n' '- Change the methodology files (`methodology/proximity.yaml`, `methodology/litmus-centicolon-wiring.yaml`).'
    printf 'Related specs:\n\n'
    printf '%s\n' '- `openspec/specs/knowledge-source-of-truth/spec.md` — authority hierarchy, CRDT-inspired convergence, evidence bundles.'
    printf '%s\n' '- `openspec/specs/observability-convergence/spec.md` — coverage, latency, staleness, dashboard reporting requirements.'
    printf '%s\n' '- `openspec/specs/spec-traceability/spec.md` — `@trace spec:<name>` semantics that link signatures to code.'
    printf '%s\n\n' '- `openspec/specs/methodology-accountability/spec.md` — CentiColon residual proximity boundary.'
    printf 'Related cheatsheets:\n\n'
    printf '%s\n' '- `docs/cheatsheets/centicolon-dashboard.md` — visual contract, tail compression, anti-gaming rules.'
    printf '%s\n' '- `cheatsheets/observability/cheatsheet-metrics.md` — metric definitions and aggregation patterns.'
    printf '%s\n' '- `cheatsheets/runtime/cheatsheet-crdt-overrides.md` — CRDT discipline this dashboard inherits.'
} >"$MD_OUT"

cp "$MD_OUT" "$SUMMARY_OUT"

if [[ "$TERMINAL_PREVIEW" == "1" ]]; then
    printf '\n[dashboard] terminal preview for %s\n' "$SERIES_LABEL" >&2
    printf '# %s\n\n' "$TITLE" >&2
    if [[ "$record_count" -eq 0 ]]; then
        printf '%s\n' "$EMPTY_HINT" >&2
    else
        printf '```text\n' >&2
        printf '%b' "$trend_windows_markdown" >&2
        printf '```\n' >&2
    fi
fi

printf 'CentiColon dashboard regenerated: %s\n' "$MD_OUT"
