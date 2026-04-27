#!/usr/bin/env bash
# pre-commit-openspec.sh — Non-blocking OpenSpec trace warnings
# @trace spec:spec-traceability, spec:cheatsheet-source-layer
#
# PHILOSOPHY: This hook ALWAYS exits 0. It NEVER blocks a commit.
#
# OpenSpec follows CRDT-inspired monotonic convergence: specs and code
# drift apart naturally, and warnings nudge them back together over time.
# A warning today becomes a fix next week — or stays as a known gap.
# Blocking commits would break flow and punish incremental progress.
#
# What it checks:
#   1. Ghost traces — @trace referencing non-existent specs
#   2. Zero-trace specs — specs with no @trace annotations in the codebase
#   3. Stale changes — active changes older than 7 days
#   4. Cheatsheet source binding — INDEX.json ↔ local: path ↔ file consistency
#      (via scripts/check-cheatsheet-sources.sh --no-sha)
#      ERRORS from the binding check are printed as warnings (never blocking).
#
# Usage:
#   Installed as .git/hooks/pre-commit (via scripts/install-hooks.sh)
#   Or run manually: bash scripts/hooks/pre-commit-openspec.sh

# No set -e — we handle errors ourselves. This hook must never abort.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { exit 0; }
SPECS_DIR="$REPO_ROOT/openspec/specs"
CHANGES_DIR="$REPO_ROOT/openspec/changes"

# Skip if openspec directory structure doesn't exist
[[ -d "$SPECS_DIR" ]] || exit 0

warnings=0

# --- 1. Ghost trace check ---------------------------------------------------
# Scan staged files for @trace spec:<name> where the spec doesn't exist.

ghost_check() {
    local staged_files
    staged_files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.(rs|sh|toml)$')" || true

    [[ -z "$staged_files" ]] && return 0

    while IFS= read -r file; do
        [[ -f "$REPO_ROOT/$file" ]] || continue

        # Extract @trace spec:<name> patterns with line numbers
        local matches
        matches="$(grep -nE '@trace\s+spec:[a-zA-Z0-9_-]+' "$REPO_ROOT/$file" 2>/dev/null)" || continue

        while IFS= read -r match_line; do
            local lineno="${match_line%%:*}"
            local content="${match_line#*:}"

            # Extract all spec names from the line (handles comma-separated)
            local specs
            specs="$(echo "$content" | grep -oE 'spec:[a-zA-Z0-9_-]+' 2>/dev/null)" || continue

            while IFS= read -r spec_ref; do
                local spec_name="${spec_ref#spec:}"
                if [[ ! -d "$SPECS_DIR/$spec_name" ]]; then
                    echo "  ⚠ OpenSpec: ghost trace '$spec_ref' in $file:$lineno — no spec exists" >&2
                    warnings=$((warnings + 1))
                fi
            done <<< "$specs"
        done <<< "$matches"
    done <<< "$staged_files"
}

# --- 2. Zero-trace spec check -----------------------------------------------
# Find specs that have zero @trace annotations anywhere in the codebase.

zero_trace_check() {
    [[ -d "$SPECS_DIR" ]] || return 0

    for spec_dir in "$SPECS_DIR"/*/; do
        [[ -d "$spec_dir" ]] || continue
        local spec_name
        spec_name="$(basename "$spec_dir")"

        # Search the codebase for any @trace referencing this spec
        # Exclude openspec/ directory and target/ build artifacts
        local found
        found="$(grep -rl --include='*.rs' --include='*.sh' --include='*.toml' \
            "spec:${spec_name}" "$REPO_ROOT" 2>/dev/null \
            | grep -v '/openspec/' \
            | grep -v '/target/' \
            | head -1)" || true

        if [[ -z "$found" ]]; then
            echo "  ⚠ OpenSpec: spec '$spec_name' has no @trace annotations in code" >&2
            warnings=$((warnings + 1))
        fi
    done
}

# --- 3. Active change staleness check ---------------------------------------
# Flag changes with created: dates older than 7 days.

staleness_check() {
    [[ -d "$CHANGES_DIR" ]] || return 0

    local today_epoch
    today_epoch="$(date +%s 2>/dev/null)" || return 0

    for yaml_file in "$CHANGES_DIR"/*/.openspec.yaml; do
        [[ -f "$yaml_file" ]] || continue

        # Skip the archive directory
        local change_dir
        change_dir="$(dirname "$yaml_file")"
        [[ "$(basename "$change_dir")" == "archive" ]] && continue

        local change_name
        change_name="$(basename "$change_dir")"

        # Extract created: date (YYYY-MM-DD format)
        local created_date
        created_date="$(grep -E '^created:\s*' "$yaml_file" 2>/dev/null \
            | head -1 | sed 's/^created:\s*//' | tr -d ' ')" || continue

        [[ -z "$created_date" ]] && continue

        # Parse date to epoch
        local created_epoch
        created_epoch="$(date -d "$created_date" +%s 2>/dev/null)" || continue

        local age_days=$(( (today_epoch - created_epoch) / 86400 ))

        if [[ "$age_days" -ge 7 ]]; then
            echo "  ⚠ OpenSpec: change '$change_name' is $age_days days old — consider archiving or updating" >&2
            warnings=$((warnings + 1))
        fi
    done
}

# --- 4. Cheatsheet source binding check ------------------------------------
# Run check-cheatsheet-sources.sh --no-sha (fast mode for pre-commit).
# Errors from the checker are printed as OpenSpec warnings — never blocking.

cheatsheet_source_check() {
    local checker="${REPO_ROOT}/scripts/check-cheatsheet-sources.sh"
    [[ -f "${checker}" ]] || return 0
    [[ -f "${REPO_ROOT}/cheatsheet-sources/INDEX.json" ]] || return 0

    local output exit_code
    output="$(bash "${checker}" --no-sha 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    if [[ "${exit_code}" -ne 0 ]]; then
        # Errors from the binding checker — surface as pre-commit warnings.
        echo "  ⚠ cheatsheet-sources: binding errors (non-blocking):" >&2
        while IFS= read -r line; do
            echo "    ${line}" >&2
        done <<< "${output}"
        warnings=$((warnings + 1))
    fi
    # Warnings (UNFETCHED) are suppressed here — they appear on manual runs.
}

# --- Run all checks ---------------------------------------------------------

echo "" >&2  # Visual separator from git's own output

ghost_check
zero_trace_check
staleness_check
cheatsheet_source_check

if [[ "$warnings" -gt 0 ]]; then
    echo "" >&2
    echo "  OpenSpec: $warnings warning(s) — not blocking commit" >&2
    echo "" >&2
fi

# Always exit 0 — see PHILOSOPHY comment at top
exit 0
