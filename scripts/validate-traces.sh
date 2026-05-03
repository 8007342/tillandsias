#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Trace Validator
#
# Phase 1: Detects ghost traces, orphaned specs, and format violations.
# Phase 2: Enforces @trace presence on public functions in src-tauri.
#
# Usage:
#   ./scripts/validate-traces.sh              # Run Phase 1 (ghost, orphan, format)
#   ./scripts/validate-traces.sh --enforce-presence  # Run Phase 2 (public fn traces)
#   ./scripts/validate-traces.sh --warn-only  # Phase 1 warnings only (exit 0)
#   ./scripts/validate-traces.sh --enforce-presence --warn-only  # Phase 2 warnings only
#
# @trace spec:spec-traceability
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$ROOT/openspec/specs"
WARN_ONLY=false
ENFORCE_PRESENCE=false
[[ "${1:-}" == "--warn-only" ]] && WARN_ONLY=true
[[ "${1:-}" == "--enforce-presence" ]] && ENFORCE_PRESENCE=true
[[ "${2:-}" == "--warn-only" ]] && WARN_ONLY=true

errors=0
warnings=0
_err() { echo "ERROR: $*" >&2; errors=$((errors+1)); }
_warn() { echo "WARN:  $*" >&2; warnings=$((warnings+1)); }

# Scan annotated source for all spec names (exclude worktrees, target)
ANNOTATED_SPECS="$(
  grep -rn --include='*.rs' --include='*.sh' --include='*.toml' --include='*.nix' \
       '@trace' \
       --exclude-dir='.claude' \
       --exclude-dir='target' \
       --exclude-dir='target-musl' \
       "$ROOT/src-tauri" "$ROOT/scripts" "$ROOT/crates" "$ROOT/images" 2>/dev/null \
  | grep 'spec:' \
  | grep -oE 'spec:[a-zA-Z0-9_-]+' \
  | sed 's/^spec://' \
  | sort -u
)"

# Get list of in-flight (non-archived) specs from active changes
IN_FLIGHT_SPECS="$(
  find "$ROOT/openspec/changes" -maxdepth 4 -name 'spec.md' \
       ! -path '*/archive/*' 2>/dev/null \
  | xargs -I{} dirname {} | xargs -I{} basename {} | sort -u
)" || IN_FLIGHT_SPECS=""

# Ghost trace check
while IFS= read -r spec_name; do
  [[ -z "$spec_name" ]] && continue
  if [[ ! -d "$SPECS_DIR/$spec_name" ]]; then
    # Check if it's in an active in-flight change
    if echo "$IN_FLIGHT_SPECS" | grep -qx "$spec_name" 2>/dev/null; then
      _warn "ghost trace 'spec:$spec_name' — in-flight change covers it"
    else
      _err "ghost trace 'spec:$spec_name' — no spec file"
    fi
  fi
done <<< "$ANNOTATED_SPECS"

# Orphan spec check
for spec_dir in "$SPECS_DIR"/*/; do
  [[ -d "$spec_dir" ]] || continue
  spec_name="$(basename "$spec_dir")"
  found="$(grep -rl --include='*.rs' --include='*.sh' --include='*.toml' \
      "spec:${spec_name}" \
      "$ROOT/src-tauri" "$ROOT/scripts" "$ROOT/crates" "$ROOT/images" 2>/dev/null \
      | head -1)" || true
  if [[ -z "$found" ]]; then
    _warn "orphaned spec '$spec_name' — no annotations"
  fi
done

# Format violation check (lightweight)
FMT_VIOLATIONS=$(grep -rn '@trace' --include='*.rs' --include='*.sh' \
    --exclude-dir='.claude' --exclude-dir='target' \
    "$ROOT/src-tauri" "$ROOT/scripts" 2>/dev/null \
  | grep 'spec:')

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"
  # Skip format checks for lines that are documentation/examples
  # If line is a comment but doesn't have an actual @trace annotation, skip it
  if [[ "$content" =~ ^[[:space:]]*(//|#).* ]] && ! [[ "$content" =~ @trace[[:space:]]+spec:[a-zA-Z0-9_-]+ ]]; then
    continue
  fi
  # Trailing comma
  if [[ "$content" =~ @trace.*spec:[a-zA-Z0-9_-]+,\ *$ ]]; then
    _warn "trailing comma: $file:$lineno"
  fi
  # Trailing prose (em-dash)
  if [[ "$content" =~ @trace.*spec:[a-zA-Z0-9_-]+.*—.* ]]; then
    _warn "em-dash note: $file:$lineno"
  fi
  # Trailing prose (paren)
  if [[ "$content" =~ @trace.*spec:[a-zA-Z0-9_-]+\ *\( ]]; then
    _warn "paren note: $file:$lineno"
  fi
  # Inline URL
  if [[ "$content" =~ @trace.*spec:[a-zA-Z0-9_-]+.*https:// ]]; then
    _warn "inline URL: $file:$lineno"
  fi
  # Inline after code (only check lines with non-comment code before @trace)
  if [[ "$content" =~ [a-zA-Z0-9\"].*//\ @trace\ spec: ]]; then
    _warn "inline-after-code: $file:$lineno"
  fi
done <<< "$FMT_VIOLATIONS"

# TRACES.md contamination
if [[ -f "$ROOT/TRACES.md" ]]; then
  grep -q '\.claude/worktrees/' "$ROOT/TRACES.md" && \
    _warn "TRACES.md contains worktree paths — regenerate"
fi

# ============================================================================
# Phase 2: Enforce @trace presence on public functions in src-tauri
# ============================================================================
if [[ "$ENFORCE_PRESENCE" == true ]]; then
  # @trace spec:enforce-trace-presence
  # Scan src-tauri/src for all public function declarations
  # Check if they have @trace annotations in preceding lines

  RUST_FILES=$(find "$ROOT/src-tauri/src" -name "*.rs" -type f \
    ! -path "*target*" ! -path "*.claude*" 2>/dev/null)

  # Temporary file to hold violations
  TMP_VIOLATIONS=$(mktemp)
  trap "rm -f $TMP_VIOLATIONS" EXIT

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Extract all public function/trait/struct/enum declarations with line numbers
    # pub fn, pub async fn, pub trait, pub struct, pub enum
    # @trace spec:enforce-trace-presence
    DECLS=$(grep -n '^[[:space:]]*pub\s\+\(async\s\+\)\?\(fn\|trait\|struct\|enum\)\s' "$file" 2>/dev/null) || continue

    while IFS= read -r decl_line; do
      [[ -z "$decl_line" ]] && continue

      # Extract line number and declaration
      decl_lineno="${decl_line%%:*}"
      decl_content="${decl_line#*:}"

      # Extract function/type name (word after fn/trait/struct/enum)
      if [[ "$decl_content" =~ pub[[:space:]]+async[[:space:]]+fn[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
        decl_name="${BASH_REMATCH[1]}"
      elif [[ "$decl_content" =~ pub[[:space:]]+fn[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
        decl_name="${BASH_REMATCH[1]}"
      elif [[ "$decl_content" =~ pub[[:space:]]+\(trait\|struct\|enum\)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
        decl_name="${BASH_REMATCH[1]}"
      else
        continue
      fi

      # Check if @trace exists in the 3 lines BEFORE the declaration
      # Look for patterns: // @trace spec: or /// @trace spec: or #![...@trace...]
      found_trace=false

      # Check up to 3 lines before
      start_line=$((decl_lineno - 3))
      [[ $start_line -lt 1 ]] && start_line=1

      # Extract lines before the declaration
      preceding=$(sed -n "${start_line},$((decl_lineno - 1))p" "$file")

      # Check for @trace annotation (// @trace spec: or /// @trace spec:)
      if echo "$preceding" | grep -qE '(//|#!?\[)\s*@trace\s+spec:'; then
        found_trace=true
      fi

      # Also check module-level #![trace(...)] attribute (applies to entire module)
      if grep -q '#!\[.*@trace.*spec:' "$file"; then
        found_trace=true
      fi

      if [[ "$found_trace" == false ]]; then
        echo "$file:$decl_lineno:$decl_name" >> "$TMP_VIOLATIONS"
      fi
    done <<< "$DECLS"
  done <<< "$RUST_FILES"

  # Report violations
  # @trace spec:enforce-trace-presence
  if [[ -s "$TMP_VIOLATIONS" ]]; then
    while IFS= read -r violation; do
      file="${violation%%:*}"
      rest="${violation#*:}"
      lineno="${rest%%:*}"
      name="${rest#*:}"
      _err "ENFORCE_TRACE: $file:$lineno $name missing @trace"
    done < "$TMP_VIOLATIONS"
  fi
fi

echo ""
echo "validate-traces: $errors error(s), $warnings warning(s)"
if [[ "$WARN_ONLY" == true ]]; then
  exit 0
fi
if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
exit 0
