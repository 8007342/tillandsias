#!/usr/bin/env bash
# check-packet-tier-declared.sh — advisory (never refuses) that a NEWLY
# DECLARED packet carries `size` and `implementer_tier` (as top-level scalars
# or as a `notes:` line, e.g. "size: S  implementer_tier: haiku").
#
# WHY. The filer assigns the tier at declaration time. An unassigned row is
# invisible to a haiku caller (it has nothing to route on) and silently
# defaults to sonnet for everyone else — fine for one row, a routing defect
# at scale. This is advisory like check-carry-forward.sh: promotion to a gate
# step waits on measured adoption (1437-cr8u).
#
# DIFF-SCOPED, same shape as check-added-fragments-parse.sh
# (TILLANDSIAS_FRAGMENT_PARSE_BASE, --diff-filter=AM): a fragment is a
# candidate only if it is added or modified versus the base ref, or wholly
# untracked. A fragment whose only top-level keys are `status:`/`events:`
# (a claim, a note, a closure) is not a declaration, even though those
# sections also carry `- packet_id:` lines — only a `packets:` section
# declares. A packet_id already present anywhere in the base tree
# (plan/index.yaml, folded, or plan/index.d fragments already landed) is not
# a NEW declaration even if the candidate fragment repeats it.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:packet-tier-declared:[0-9]+|advisory:packet-tier-undeclared:[0-9]+)$
# Always exits 0 — advisory, never a gate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FRAG_DIR="plan/index.d"
base_ref="${TILLANDSIAS_FRAGMENT_PARSE_BASE:-origin/linux-next}"

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok:packet-tier-declared:0"
    echo "  note: base ref '$base_ref' unavailable — packet-tier-declared check skipped" >&2
    exit 0
fi

# Every packet_id already known to the base tree (folded ledger + fragments
# already landed there), gathered with one archive-and-grep pass instead of a
# per-file git show (thousands of fragment files at this ledger's size).
base_tmp="$(mktemp -d)"
trap 'rm -rf "$base_tmp"' EXIT
git archive "$base_ref" -- plan/index.yaml "$FRAG_DIR" 2>/dev/null | tar -x -C "$base_tmp" 2>/dev/null || true
base_ids_file="$base_tmp/.base_ids"
grep -rhoE 'packet_id:[[:space:]]*[A-Za-z0-9_-]+' "$base_tmp" 2>/dev/null \
    | sed -E 's/^packet_id:[[:space:]]*//' | sort -u >"$base_ids_file"

is_known() {
    grep -qFx -- "$1" "$base_ids_file"
}

candidates="$(
    {
        git diff --name-only --diff-filter=AM "$base_ref" -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=AM -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
    } | sort -u
)"

declared=0
undeclared=0

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue

    # Only the packets: section declares; status:/events: sections merely
    # carry packet_id references to an existing row.
    packets_section="$(awk '
        /^packets:/ { in_packets=1; next }
        in_packets && /^[A-Za-z_]+:/ { in_packets=0 }
        in_packets { print }
    ' "$f")"
    [ -n "$packets_section" ] || continue

    # Split into per-packet blocks on each "  - packet_id:" boundary.
    block=""
    pid=""
    flush() {
        [ -n "$pid" ] || return 0
        if is_known "$pid"; then
            return 0
        fi
        if grep -qE '(^|[[:space:]])size:[[:space:]]*[^[:space:]]' <<<"$block" \
            && grep -qE '(^|[[:space:]])implementer_tier:[[:space:]]*[^[:space:]]' <<<"$block"; then
            declared=$((declared + 1))
        else
            undeclared=$((undeclared + 1))
            echo "advisory: $pid declared with no size/implementer_tier (top-level or notes-line)" >&2
        fi
    }
    while IFS= read -r line; do
        if grep -qE '^[[:space:]]*-[[:space:]]*packet_id:' <<<"$line"; then
            flush
            pid="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*packet_id:[[:space:]]*//')"
            block="$line"$'\n'
        else
            block="$block$line"$'\n'
        fi
    done <<EOF
$packets_section
EOF
    flush
done <<EOF
$candidates
EOF

if [ "$undeclared" -gt 0 ]; then
    echo "advisory:packet-tier-undeclared:$undeclared"
    exit 0
fi
echo "ok:packet-tier-declared:$declared"
exit 0
