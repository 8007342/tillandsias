#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Trace Validator
#
# Detects ghost traces, orphaned specs, and format violations.
# Usage: ./scripts/validate-traces.sh [--warn-only]
# @trace spec:spec-traceability
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$ROOT/openspec/specs"
WARN_ONLY=false
[[ "${1:-}" == "--warn-only" ]] && WARN_ONLY=true

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
  # Inline after code
  if [[ "$content" =~ [a-zA-Z0-9\"].*//\ @trace\ spec: ]]; then
    _warn "inline-after-code: $file:$lineno"
  fi
done <<< "$FMT_VIOLATIONS"

# TRACES.md contamination
if [[ -f "$ROOT/TRACES.md" ]]; then
  grep -q '\.claude/worktrees/' "$ROOT/TRACES.md" && \
    _warn "TRACES.md contains worktree paths — regenerate"
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
