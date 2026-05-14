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
  "trend_windows": $trend_windows_json,
  "latest": $latest_json,
  "history": $history_json
}
EOF

{
    printf '# %s\n\n' "$TITLE"

    printf '```text\n'
    if [[ "$record_count" -gt 0 ]]; then
        printf '%b' "$trend_windows_markdown"
    fi
    printf '```\n'
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
