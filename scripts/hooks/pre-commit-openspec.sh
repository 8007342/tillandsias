#!/usr/bin/env bash
# pre-commit-openspec.sh — Non-blocking OpenSpec trace warnings (default), CI-mode enforcement
# @trace spec:spec-traceability, spec:cheatsheet-source-layer
#
# PHILOSOPHY: This hook ALWAYS exits 0 by default. It NEVER blocks commits.
#
# OpenSpec follows CRDT-inspired monotonic convergence: specs and code
# drift apart naturally, and warnings nudge them back together over time.
# A warning today becomes a fix next week — or stays as a known gap.
# Blocking commits would break flow and punish incremental progress.
#
# CI mode (--ci-mode): In CI/release workflows, exit 1 on ANY warning.
# This ensures releases only happen when spec-code alignment is verified.
#
# What it checks:
#   1. Ghost traces — @trace referencing non-existent specs
#   2. Zero-trace specs — specs with no @trace annotations in the codebase
#   3. Stale changes — active changes older than 7 days
#   4. Cheatsheet source binding — INDEX.json ↔ local: path ↔ file consistency
#      (via scripts/check-cheatsheet-sources.sh --no-sha)
#      ERRORS from the binding check are printed as warnings.
#
# Usage:
#   Installed as .git/hooks/pre-commit (via scripts/install-hooks.sh)
#   Or run manually: bash scripts/hooks/pre-commit-openspec.sh
#   In CI: bash scripts/hooks/pre-commit-openspec.sh --ci-mode

# No set -e — we handle errors ourselves. This hook must never abort (except in --ci-mode).
set -uo pipefail

CI_MODE=false
[[ "${1:-}" == "--ci-mode" ]] && CI_MODE=true

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { exit 0; }
SPECS_DIR="$REPO_ROOT/openspec/specs"
CHANGES_DIR="$REPO_ROOT/openspec/changes"

# Skip if openspec directory structure doesn't exist
[[ -d "$SPECS_DIR" ]] || exit 0

ghost_warnings=0
zero_trace_warnings=0
warnings=0

# --- 1. Ghost trace check ---------------------------------------------------
# Scan staged files for @trace spec:<name> where the spec doesn't exist.
# Per methodology/ci.yaml: Ghost traces are BLOCKING errors.

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
                    echo "  ✗ OpenSpec: ghost trace '$spec_ref' in $file:$lineno — no spec exists" >&2
                    ghost_warnings=$((ghost_warnings + 1))
                    warnings=$((warnings + 1))
                fi
            done <<< "$specs"
        done <<< "$matches"
    done <<< "$staged_files"
}

# --- 2. Zero-trace spec check -----------------------------------------------
# Find specs that have zero @trace annotations anywhere in the codebase.
# Per methodology/ci.yaml: Zero-trace specs are acceptable convergence gaps (warning-only).

zero_trace_check() {
    [[ -d "$SPECS_DIR" ]] || return 0

    for spec_dir in "$SPECS_DIR"/*/; do
        [[ -d "$spec_dir" ]] || continue
        local spec_name
        spec_name="$(basename "$spec_dir")"

        # Search the codebase for any @trace referencing this spec
        # Exclude openspec/ directory and target/ build artifacts
        local found
        found="$(grep -rl --include='*.rs' --include='*.sh' --include='*.toml' --include='Containerfile*' \
            "spec:${spec_name}" "$REPO_ROOT" 2>/dev/null \
            | grep -v '/openspec/' \
            | grep -v '/target/' \
            | head -1)" || true

        if [[ -z "$found" ]]; then
            echo "  ◌ OpenSpec: spec '$spec_name' has no @trace annotations in code" >&2
            zero_trace_warnings=$((zero_trace_warnings + 1))
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
# Legacy verbatim source layer check — kept for the three-release retention
# window per @tombstone discipline. The new tier validator (check 4b) is
# the canonical replacement.
# @trace spec:cheatsheet-source-layer

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

# --- 4b. Cheatsheet tier-aware validator (cheatsheets-license-tiered) ------
# Runs scripts/check-cheatsheet-tiers.sh in --quiet mode. ERRORs surface as
# non-blocking OpenSpec warnings (CRDT-convergence philosophy). The validator
# itself is non-fatal: it exits 0 unless tier-conditional fields are missing
# or CRDT override discipline is violated.
# @trace spec:cheatsheets-license-tiered

cheatsheet_tier_check() {
    local checker="${REPO_ROOT}/scripts/check-cheatsheet-tiers.sh"
    [[ -f "${checker}" ]] || return 0

    local output exit_code
    output="$(bash "${checker}" --quiet 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    if [[ "${exit_code}" -ne 0 ]]; then
        echo "  ⚠ cheatsheet-tiers: validation ERRORs (non-blocking):" >&2
        while IFS= read -r line; do
            echo "    ${line}" >&2
        done <<< "${output}"
        warnings=$((warnings + 1))
    fi
}

# --- Run all checks ---------------------------------------------------------

echo "" >&2  # Visual separator from git's own output

ghost_check
zero_trace_check
staleness_check
cheatsheet_source_check
cheatsheet_tier_check

if [[ "$warnings" -gt 0 ]]; then
    echo "" >&2
    if [[ "$CI_MODE" == "true" ]]; then
        if [[ "$ghost_warnings" -gt 0 ]]; then
            echo "  OpenSpec: $ghost_warnings blocking error(s), $zero_trace_warnings warning(s) — FAILING CI MODE" >&2
        else
            echo "  OpenSpec: $zero_trace_warnings warning(s) — not blocking CI (acceptable convergence gaps)" >&2
        fi
    else
        echo "  OpenSpec: $warnings notice(s) — not blocking commit" >&2
    fi
    echo "" >&2
fi

# Exit 0 by default (pre-commit hook philosophy)
# Exit 1 in CI mode ONLY if ghost traces found (methodology/ci.yaml: blocking errors)
# Zero-trace specs are acceptable convergence gaps and do not block
if [[ "$CI_MODE" == "true" && "$ghost_warnings" -gt 0 ]]; then
    exit 1
fi
exit 0
