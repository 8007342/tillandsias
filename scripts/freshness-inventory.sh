#!/usr/bin/env bash
# freshness: auditor=forge-forge-tillandsias-codex-20260723T0402Z date=2026-07-23 verdict=refreshed scope=revalidated inventory paths, first-record grammar, advisory output contract, local-ci consumer, and 931-component runtime
# =============================================================================
# freshness-inventory.sh — FRESHNESS rung 2: component inventory + coverage
#
# Inventories auditable components (scripts/*, images/default/*, cheatsheets,
# litmus tests, methodology docs) and reports freshness coverage:
#   - stamped (carries a `# freshness:` record per methodology.yaml
#     component_freshness.freshness_record_grammar)
#   - unstamped
#   - age distribution (relative to the freshest stamp seen)
#
# Emits a PINNED, machine-greppable report grammar (see README below) and an
# exit-code contract so CI/local-ci can consume it (rung 3 adds advisory
# flagging on top of this report).
#
# Exit codes:
#   0  report produced (coverage reported; staleness is advisory, not a failure)
#   2  usage / IO error
#
# Report grammar (stable — pinned by litmus:freshness-inventory-shape):
#   freshness-inventory: <total> components, <stamped> stamped, <unstamped> unstamped
#   freshness-coverage: <integer>%
#   freshness-stamp: <relpath> <verdict> <date> <auditor>
#   freshness-unstamped: <relpath>
#   freshness-stale: <relpath> <age_days> <verdict> <date>
#
# A `# freshness:` record line looks like (one of):
#   # freshness: auditor=<agent-id> date=<ISO-date> verdict=<refreshed|updated|obsoleted> scope=<one-line>
# The first `# freshness:` line in a file wins.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STAMP_RE='^[[:space:]]*(#|//|\*+[[:space:]]*)?[[:space:]]*freshness:[[:space:]]+auditor=([^[:space:]]+)[[:space:]]+date=([0-9T:Z-]+)[[:space:]]+verdict=(refreshed|updated|obsoleted)[[:space:]]*scope=(.*)$'

# Components to inventory, relative to REPO_ROOT.
INVENTORY_PATHS=(
    "scripts"
    "images/default"
    "cheatsheets"
    "openspec/litmus-tests"
    "methodology"
)

# Collect candidate files: shell scripts everywhere, plus yaml/md under the
# named dirs (cheatsheets, litmus tests, methodology docs).
mapfile -t CANDIDATES < <(
    # shell scripts + C helpers anywhere under scripts/
    find scripts -type f \( -name '*.sh' -o -name '*.c' \) 2>/dev/null
    for d in "${INVENTORY_PATHS[@]:1}"; do
        [ -d "$d" ] || continue
        find "$d" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.md' \) 2>/dev/null
    done
)

total=0
stamped=0
declare -a STAMP_LINES
declare -a UNSTAMPED_LINES

today="$(date -u +%Y-%m-%d)"

for f in "${CANDIDATES[@]}"; do
    # Only count files that exist and are regular files.
    [ -f "$f" ] || continue
    total=$((total + 1))
    rel="${f#./}"
    # Find the first freshness record in the file.
    rec="$(grep -m1 -E "$STAMP_RE" "$f" 2>/dev/null || true)"
    if [[ -n "$rec" ]]; then
        if [[ "$rec" =~ $STAMP_RE ]]; then
            auditor="${BASH_REMATCH[2]}"
            fdate="${BASH_REMATCH[3]}"
            verdict="${BASH_REMATCH[4]}"
            stamped=$((stamped + 1))
            STAMP_LINES+=("$rel|$verdict|$fdate|$auditor")
            # Age in days since the stamp date (best-effort; ignores TZ/time).
            age_days=""
            fdate_day="${fdate:0:10}"
            if [[ "$fdate_day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                ts_stamp="$(date -u -d "$fdate_day" +%s 2>/dev/null || true)"
                ts_today="$(date -u -d "$today" +%s 2>/dev/null || true)"
                if [[ -n "$ts_stamp" && -n "$ts_today" ]]; then
                    age_days=$(( (ts_today - ts_stamp) / 86400 ))
                    [[ $age_days -lt 0 ]] && age_days=0
                fi
            fi
            if [[ -n "$age_days" ]]; then
                printf 'freshness-stale: %s %s %s %s\n' "$rel" "$age_days" "$verdict" "$fdate"
            fi
        fi
    else
        UNSTAMPED_LINES+=("$rel")
    fi
done

unstamped=$((total - stamped))
if [[ $total -gt 0 ]]; then
    pct=$(( stamped * 100 / total ))
else
    pct=0
fi

echo "freshness-inventory: $total components, $stamped stamped, $unstamped unstamped"
echo "freshness-coverage: ${pct}%"
for line in "${STAMP_LINES[@]:-}"; do
    [ -z "$line" ] && continue
    IFS='|' read -r rel verdict fdate auditor <<< "$line"
    echo "freshness-stamp: $rel $verdict $fdate $auditor"
done
for rel in "${UNSTAMPED_LINES[@]:-}"; do
    [ -z "$rel" ] && continue
    echo "freshness-unstamped: $rel"
done

exit 0
