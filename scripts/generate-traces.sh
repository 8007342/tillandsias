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
#   ./scripts/generate-traces.sh            # regenerate the tracked indexes
#   ./scripts/generate-traces.sh --check    # report staleness, mutate NOTHING
#
# --check exists because there was previously NO command that answered "are the
# committed trace indexes current?" with an exit code. The generator was a pure
# writer: it always rewrote every index, printed `Written:` whether or not
# content changed, never compared against git, and structurally could not exit
# non-zero. So the invariant was unenforceable by construction, not merely
# unenforced — every consumer had to hand-roll a `git status` comparison, and
# none did. The result: adding an @trace and shipping left TRACES.md dirty with
# zero signal, and the next agent's pre-build sweep failed
# litmus:local-ci-self-clean-evidence for dirt it did not create. That happened
# three separate times in one day (orders 480, then 482a/484, then 579c54e3).
#
# PINNED GRAMMAR for --check — exactly one line on stdout:
#   ok:trace-indexes-current
#   stale:trace-indexes count=<N>
# Exit 0 when current, 1 when stale. Stale paths are listed on stderr with the
# exact remedy, so an agent is never left guessing what to run.
#
# No external dependencies — uses only grep, find, sort, awk, sed.
# =============================================================================

set -euo pipefail

# @trace spec:clickable-trace-index

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_MODE=0
case "${1:-}" in
    --check) CHECK_MODE=1 ;;
    "") ;;
    *) echo "usage: generate-traces.sh [--check]" >&2; exit 2 ;;
esac

# INPUTS always come from the real checkout. Only OUTPUT is redirected, so
# --check can generate into a throwaway tree and diff, touching no tracked file.
OUT_ROOT="$ROOT"
if [[ "$CHECK_MODE" == "1" ]]; then
    OUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-traces-check.XXXXXX")"
    trap 'rm -rf "$OUT_ROOT"' EXIT
fi

TRACES_MD="$OUT_ROOT/TRACES.md"
OPENSPEC_SPECS="$ROOT/openspec/specs"
OPENSPEC_ARCHIVE="$ROOT/openspec/changes/archive"

# Quiet the per-file chatter in --check; the pinned line is the whole output.
_gt_say() { [[ "$CHECK_MODE" == "1" ]] || echo "$@"; }

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

_gt_say "[generate-traces] Written: TRACES.md"

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
        # Output is OUT_ROOT-relative so --check writes into the throwaway tree.
        per_spec_md="$OUT_ROOT/openspec/specs/${spec_name}/TRACES.md"
        mkdir -p "$(dirname "$per_spec_md")"

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

        _gt_say "[generate-traces] Written: openspec/specs/${spec_name}/TRACES.md"
    done <<< "$UNIQUE_SPECS"
fi

if [[ "$CHECK_MODE" == "1" ]]; then
    # Compare every generated artifact against its committed counterpart.
    # Compare against what is COMMITTED (git HEAD), not against the working
    # tree. The failure this guard prevents is shipping an @trace change without
    # its index refresh, so the question that matters is "are the COMMITTED
    # indexes current?" — not "would regeneration be a no-op right now?". A
    # working-tree comparison answers the second, and reports `ok` while
    # freshly-regenerated indexes sit UNCOMMITTED — which is exactly the state
    # that breaks the next agent.
    stale=()
    while IFS= read -r produced; do
        rel="${produced#$OUT_ROOT/}"
        if ! git -C "$ROOT" cat-file -e "HEAD:$rel" 2>/dev/null; then
            # Never committed — a new spec's index counts as stale.
            stale+=("$rel")
            continue
        fi
        if ! git -C "$ROOT" show "HEAD:$rel" 2>/dev/null | cmp -s - "$produced"; then
            stale+=("$rel")
        fi
    done < <(find "$OUT_ROOT" -name TRACES.md -type f | sort)

    if [[ ${#stale[@]} -eq 0 ]]; then
        echo "ok:trace-indexes-current"
        exit 0
    fi
    echo "stale:trace-indexes count=${#stale[@]}"
    {
        echo "[generate-traces] The committed trace indexes do NOT match the current @trace annotations."
        echo "[generate-traces] Stale paths:"
        for f in "${stale[@]}"; do echo "  $f"; done
        echo "[generate-traces] REMEDY — run BOTH, in the SAME commit as your @trace change:"
        echo "    ./scripts/generate-traces.sh"
        echo "    git add TRACES.md openspec/specs/*/TRACES.md"
        echo "[generate-traces] Leaving these uncommitted fails litmus:local-ci-self-clean-evidence"
        echo "[generate-traces] for the NEXT agent, far from the cause. See methodology: generated evidence."
    } >&2
    exit 1
fi

echo "[generate-traces] Done."
