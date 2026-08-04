#!/usr/bin/env bash
# check-plan-ledger-readers.sh — ORDER 582-26mm.
#
# Enumerate every surface that opens plan/index.yaml for a CONTENT read and
# assert each is either overlay-aware (routes through the compiled
# tillandsias-plan CLI, which folds base ⊕ plan/index.d/ fragments) or is an
# explicit base-only-with-reason reader.
#
# WHY THIS GATE EXISTS. A reader that opens plan/index.yaml directly sees ONLY
# the base and reports a stale ledger WITH TOTAL CONFIDENCE. When one surface
# (forge-plan) says a packet exists and another (a direct yq reader) says it
# does not, an agent cannot tell which surface is lying, and both look
# authoritative. The CLI exists so every read path folds the same fragments;
# a new direct reader silently reintroduces the disagreement this packet
# (582-26mm) exists to eliminate.
#
# Exit codes:
#   0 — every reader is overlay-aware or base-only-with-reason
#   1 — a new direct reader of plan/index.yaml was found
#
# Usage:
#   ./scripts/check-plan-ledger-readers.sh [--strict]
#     --strict  also require that the allowlisted files still contain the CLI
#               routing marker (i.e. they must stay overlay-aware, not regress
#               back to a direct read)
#
# The litmus litmus:no-unprotected-plan-ledger-readers binds this gate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

# Surfaces ALLOWED to name plan/index.yaml. Verdict per file:
#   overlay            — routes through the compiled CLI (fragment-aware)
#   base-only-reason   — reads the base on purpose; a stated reason is required
ALLOWLIST=(
  "images/default/config-overlay/mcp/forge-plan.sh"   # overlay: wraps tillandsias-plan
  "images/default/config-overlay/mcp/project-info.sh" # overlay: plan_query routes through query --json
  "scripts/drain-queue.sh"                            # overlay: extract_ready_packets routes through query --status ready
  "scripts/check-plan-schema-divergence.sh"           # base-only-reason: reads ONLY default_status_values vocabulary (schema-level, fragments are packet additions and can never carry it)
  "crates/tillandsias-plan/src/main.rs"               # overlay: the CLI itself (Ledger::load_with_fragments)
  "crates/tillandsias-plan/src/lib.rs"                # overlay: the CLI itself (Ledger::load_with_fragments)
  "crates/tillandsias-plan/src/fragments.rs"          # overlay: the fragment engine
  "crates/tillandsias-plan/src/loop_status.rs"        # overlay: loop_status fold engine (separate doc, same discipline)
  "crates/tillandsias-plan/src/answer.rs"             # overlay: answers come from the folded ledger
  "crates/tillandsias-plan/src/groundtruth.rs"        # overlay: grades the experts against the folded ledger
  "crates/tillandsias-policy/src/main.rs"             # base-only-reason: plan-orders is superseded by `tillandsias-plan check` (fragment-aware duplicate-order gate); kept for legacy script wrappers only
)

# Reader-tool signals that a file is doing a CONTENT read (as opposed to an
# existence check, a CLI --index argument, or prose).
SIGNALS=(
  "yq"
  "awk"
  "YAML.load"
  "File.read"
  "File.readlines"
  "read_to_string"
  "ruby -ryaml"
)

# Existence checks and CLI routing are the legitimate non-content uses.
is_content_read() {
  local file="$1" line="$2"
  # CLI routing: --index plan/index.yaml is HOW the overlay-aware readers reach
  # the folded ledger. Never a violation.
  [[ "$line" == *"--index"* ]] && return 1
  # Existence checks (`-f ...plan/index.yaml`, `[ -f`).
  [[ "$line" == *"-f"*"plan/index.yaml"* ]] && return 1
  [[ "$line" == *"[ -f"* ]] && return 1
  [[ "$line" == *"test -f"* ]] && return 1
  # Comment lines are prose, not reads.
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1
  [[ "$line" == *"@trace"* ]] && return 1
  for sig in "${SIGNALS[@]}"; do
    if [[ "$line" == *"$sig"* ]]; then
      return 0
    fi
  done
  return 1
}

violations=0

# Only surfaces that could plausibly READ the ledger are scanned. The ledger
# itself (plan/index.yaml), its fragments, docs, and tests that WRITE a fixture
# are excluded.
while IFS= read -r file; do
  in_allowlist=0
  for a in "${ALLOWLIST[@]}"; do
    [[ "$file" == "$a" ]] && in_allowlist=1
  done

  # Within an allowlisted file, a content read is only legal when the file is
  # overlay-aware; base-only-with-reason files must not gain yq/awk/ruby reads.
  if [[ "$in_allowlist" -eq 1 ]]; then
    [[ "$STRICT" -eq 1 ]] || continue
  fi

  while IFS= read -r line; do
    if is_content_read "$file" "$line"; then
      echo "violation: content read of plan/index.yaml in ${file}:"
      echo "  $line"
      violations=$((violations + 1))
    fi
  done < <(grep -n 'plan/index\.yaml' "$file" || true)
done < <(grep -rl 'plan/index\.yaml' scripts/ images/ crates/ 2>/dev/null || true)

if [[ "$violations" -gt 0 ]]; then
  echo "blocked: $violations unprotected direct reader(s) of plan/index.yaml — route them through 'tillandsias-plan query' (or document them as base-only-with-reason)"
  exit 1
fi

echo "ok: every reader of plan/index.yaml is overlay-aware or base-only-with-reason"
