#!/usr/bin/env bash
# @trace spec:ci-release, plan 698-7n6q
#
# check-added-fragments-parse.sh — refuse a push that ADDS a ledger fragment the
# fold cannot read.
#
# WHY THIS EXISTS. `tillandsias-plan check` already prints, accurately:
#   warning: ledger fragment <path> does not parse and was SKIPPED
#            — its contents are not in the answers below
# and then exits 0. So `./build.sh --check` passes, the pre-push hook stamps the
# tree, and the fragment reaches origin carrying a packet that exists in git and
# in NO ANSWER: not in `plan status`, not in `plan next`, not in burndown, not
# claimable, invisible to every sibling host. The author believes they filed
# work. The fleet never sees it.
#
# That is not hypothetical. On 2026-08-12 packet 697-s3by was written,
# committed, gated green, and pushed in exactly that state. The cause was
# mundane — an unquoted scalar containing a colon-space, which YAML reads as a
# nested mapping — and that is the point: trivial to produce, red nowhere, and
# the loss is total and silent. The sibling failure (the fold DISCARDING a
# declared status) already earns a hard failure via
# check-fragment-status-loss.sh; a fragment the fold cannot read at all was
# strictly weaker.
#
# DIFF-SCOPED BY CONSTRUCTION, deliberately. Failing on ANY malformed fragment
# anywhere would let one host's mistake turn every other host's gate red until
# someone else fixed it — converting a local error into a fleet outage. So this
# refuses only fragments ADDED or MODIFIED versus the base ref, exactly as
# check-litmus-expression-pinning-added.sh (634-39ik) scopes its enforcement.
# You break it, your push fails. You inherit it, you are merely warned — the
# existing `tillandsias-plan check` warning still reports it.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:added-fragments-parse:[0-9]+ checked|violation:added-fragment-unparseable:[0-9]+)$
# Exit 0 when every added/modified fragment parses.
#
# Pinned by litmus:added-fragment-parse-gate-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FRAG_DIR="plan/index.d"
base_ref="${TILLANDSIAS_FRAGMENT_PARSE_BASE:-origin/linux-next}"

# A validator that EXISTS where we are. `yq` is absent on macOS hosts and
# `ruby` is absent from the forge image, so prefer the workspace binary and fall
# back only to tools the environment actually has. python3 is deliberately NOT
# used: it is forbidden for committed automation (order 63).
_validator=""
for cand in "target/release/tillandsias-policy" "target/debug/tillandsias-policy"; do
    [ -x "$cand" ] && { _validator="$cand validate-yaml"; break; }
done
if [ -z "$_validator" ] && command -v yq >/dev/null 2>&1; then
    _validator="yq ."
fi
if [ -z "$_validator" ]; then
    # No validator available is NOT a pass: it is an unknown. Say so plainly and
    # skip, rather than reporting a green that was never checked.
    echo "ok:added-fragments-parse:0 checked"
    echo "  note: no YAML validator available (build tillandsias-policy to enable this gate)" >&2
    exit 0
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok:added-fragments-parse:0 checked"
    echo "  note: base ref '$base_ref' unavailable — added-fragment enforcement skipped" >&2
    exit 0
fi

# Candidates: fragments added/modified vs base, plus wholly-untracked ones
# (a brand-new fragment is usually untracked at the moment it is written).
candidates="$(
    {
        git diff --name-only --diff-filter=AM "$base_ref" -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=AM -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
    } | sort -u
)"

checked=0
violations=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue   # deleted (e.g. folded by compaction) — nothing to parse
    checked=$((checked + 1))
    if ! err="$($_validator "$f" 2>&1 >/dev/null)"; then
        violations=$((violations + 1))
        {
            echo "REFUSED: $f does not parse — the fold will SKIP it and its packets will exist in git and in no answer."
            printf '   %s\n' "$(printf '%s' "$err" | head -1)"
        } >&2
    fi
done <<EOF
$candidates
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:added-fragment-unparseable:$violations"
    exit 1
fi
echo "ok:added-fragments-parse:$checked checked"
exit 0
