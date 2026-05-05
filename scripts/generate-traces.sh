#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Trace Index Generator
#
# Scans all .rs, .sh, .toml, .nix files for @trace spec:<name> annotations
# and generates:
#   - TRACES.md at the repo root (spec → source files table)
#   - openspec/specs/<name>/TRACES.md per active spec (back-links)
#
# Usage:
#   ./scripts/generate-traces.sh
#
# No external dependencies — uses only grep, find, sort, awk, sed.
# =============================================================================

set -euo pipefail

# @trace spec:clickable-trace-index

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TRACES_MD="$ROOT/TRACES.md"
OPENSPEC_SPECS="$ROOT/openspec/specs"
OPENSPEC_ARCHIVE="$ROOT/openspec/changes/archive"

# ---------------------------------------------------------------------------
# Step 1: Scan — collect all @trace spec: annotations
# Format: <relative-path>:<line>:<spec-name>   (one spec per line)
# ---------------------------------------------------------------------------

RAW_ENTRIES=""

while IFS= read -r match; do
    # match is:  ./path/to/file.rs:42:... @trace spec:<name>/sub-path ...
    filepath="${match%%:*}"
    remainder="${match#*:}"
    lineno="${remainder%%:*}"
    annotation="${remainder#*:}"

    # Relative path from repo root (strip leading ./)
    relpath="${filepath#./}"

    # Extract all spec: tokens from the annotation line
    # Handles: spec:foo, spec:foo/sub-req, multiple on one line
    while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        # Strip sub-path: spec:podman-orchestration/security → podman-orchestration
        spec_name="${token%%/*}"
        RAW_ENTRIES="${RAW_ENTRIES}${relpath}:${lineno}:${spec_name}"$'\n'
    done < <(printf '%s' "$annotation" | grep -oE 'spec:[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)?' | sed 's/^spec://')

done < <(
    cd "$ROOT"
    grep -rn "@trace" \
        --include="*.rs" \
        --include="*.sh" \
        --include="*.toml" \
        --include="*.nix" \
        --include="Containerfile*" \
        --exclude-dir='.claude' \
        --exclude-dir='target' \
        --exclude-dir='target-musl' \
        . 2>/dev/null \
        | grep "spec:" \
        || true
)

# ---------------------------------------------------------------------------
# Step 2: Build unique spec list (sorted)
# ---------------------------------------------------------------------------

UNIQUE_SPECS=""
if [[ -n "$RAW_ENTRIES" ]]; then
    UNIQUE_SPECS="$(printf '%s' "$RAW_ENTRIES" | awk -F: '{print $3}' | sort -u)"
fi

# ---------------------------------------------------------------------------
# Step 3: Locate spec file for each unique spec name
# ---------------------------------------------------------------------------

# Returns relative path from ROOT to spec file, or empty string if not found
_locate_spec() {
    local name="$1"
    # 1. Active spec directory
    local active_path="openspec/specs/${name}/spec.md"
    if [[ -f "$ROOT/$active_path" ]]; then
        printf '%s' "$active_path"
        return
    fi
    # 2. In-progress change (not yet archived): openspec/changes/*/specs/<name>/spec.md
    local change_path
    change_path="$(find "$ROOT/openspec/changes" -maxdepth 4 \
        -path "*/specs/${name}/spec.md" \
        ! -path "*/archive/*" 2>/dev/null | head -1 || true)"
    if [[ -n "$change_path" ]]; then
        printf '%s' "${change_path#$ROOT/}"
        return
    fi
    # 3. Archive
    local archive_path
    archive_path="$(find "$OPENSPEC_ARCHIVE" -path "*/specs/${name}/spec.md" 2>/dev/null | head -1 || true)"
    if [[ -n "$archive_path" ]]; then
        # Make relative to ROOT
        printf '%s' "${archive_path#$ROOT/}"
        return
    fi
    printf ''
}

# ---------------------------------------------------------------------------
# Step 4: Build the root TRACES.md
# ---------------------------------------------------------------------------

{
    printf '# Trace Index\n\n'
    printf 'Generated automatically from `@trace` comments in the codebase.\n'
    printf 'Run `./scripts/generate-traces.sh` to regenerate.\n\n'

    if [[ -z "$UNIQUE_SPECS" ]]; then
        printf '> No `@trace spec:` annotations found in the codebase.\n'
    else
        printf '| Trace | Spec | Source Files |\n'
        printf '|-------|------|--------------|\n'

        while IFS= read -r spec_name; do
            [[ -z "$spec_name" ]] && continue

            # Spec link
            spec_file="$(_locate_spec "$spec_name")"
            if [[ -z "$spec_file" ]]; then
                spec_cell="(not found)"
            elif [[ "$spec_file" == openspec/changes/archive/* ]]; then
                spec_cell="[(archived) ${spec_name}/spec.md](${spec_file})"
            else
                spec_cell="[${spec_name}/spec.md](${spec_file})"
            fi

            # Source file links — all occurrences for this spec
            source_links=""
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                entry_spec="${entry##*:}"
                [[ "$entry_spec" != "$spec_name" ]] && continue
                # Strip spec suffix
                without_spec="${entry%:*}"
                entry_line="${without_spec##*:}"
                entry_file="${without_spec%:*}"
                filename="$(basename "$entry_file")"
                link="[${filename}](${entry_file}#L${entry_line})"
                if [[ -z "$source_links" ]]; then
                    source_links="$link"
                else
                    source_links="${source_links}, ${link}"
                fi
            done < <(printf '%s' "$RAW_ENTRIES" | sort -t: -k1,1 -k2,2n)

            printf '| `spec:%s` | %s | %s |\n' \
                "$spec_name" \
                "$spec_cell" \
                "$source_links"
        done <<< "$UNIQUE_SPECS"
    fi
} > "$TRACES_MD"

echo "[generate-traces] Written: TRACES.md"

# ---------------------------------------------------------------------------
# Step 5: Per-spec TRACES.md (active specs only)
# ---------------------------------------------------------------------------

if [[ -n "$UNIQUE_SPECS" ]]; then
    while IFS= read -r spec_name; do
        [[ -z "$spec_name" ]] && continue

        # Only generate for active (non-archived) specs
        active_spec="$OPENSPEC_SPECS/${spec_name}/spec.md"
        [[ ! -f "$active_spec" ]] && continue

        spec_dir="$OPENSPEC_SPECS/${spec_name}"
        per_spec_md="$spec_dir/TRACES.md"

        # Collect source entries for this spec
        entries_for_spec=""
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            entry_spec="${entry##*:}"
            [[ "$entry_spec" != "$spec_name" ]] && continue
            without_spec="${entry%:*}"
            entry_line="${without_spec##*:}"
            entry_file="${without_spec%:*}"
            entries_for_spec="${entries_for_spec}${entry_file}:${entry_line}"$'\n'
        done < <(printf '%s' "$RAW_ENTRIES" | sort -t: -k1,1 -k2,2n)

        [[ -z "$entries_for_spec" ]] && continue

        # Relative path from spec dir back to repo root
        # openspec/specs/<name>/ → ../../..  (3 levels up)
        rel_root="../../.."

        {
            printf '# Traces for %s\n\n' "$spec_name"
            printf 'Code implementing this spec (auto-generated — do not edit).\n'
            printf 'Run `./scripts/generate-traces.sh` to regenerate.\n\n'
            printf '## Annotated locations\n\n'
            while IFS= read -r src_entry; do
                [[ -z "$src_entry" ]] && continue
                src_line="${src_entry##*:}"
                src_file="${src_entry%:*}"
                printf -- '- [%s#L%s](%s/%s#L%s)\n' \
                    "$src_file" "$src_line" \
                    "$rel_root" "$src_file" "$src_line"
            done <<< "$entries_for_spec"
        } > "$per_spec_md"

        echo "[generate-traces] Written: openspec/specs/${spec_name}/TRACES.md"
    done <<< "$UNIQUE_SPECS"
fi

echo "[generate-traces] Done."
