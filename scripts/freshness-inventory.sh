#!/usr/bin/env bash
# freshness: auditor=linux-macuahuitl-fable5-20260811t0200z date=2026-08-11 verdict=refreshed scope=behavioral re-validation: emitted the coverage report + freshness-stale/freshness-next grammar live this cycle (6 loop iterations consumed it to pick audit targets), litmus:freshness-inventory-shape PASS; the windows-20260809 freshness-next: unstamped-draw fix is live and working — the queue advanced through podman-mock/tls-test-server/run-litmus-test rather than re-offering the same 8
# freshness: auditor=windows-claude-20260809t212955z date=2026-08-09 verdict=updated scope=coverage stuck at 0% for 9+ days because the advisory could only rank STAMPED files, so the audit queue re-offered the same 8 and the 1013 unstamped were unreachable; added freshness-next: to draw the next target from the unstamped set
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
#   freshness-next: <relpath> <source=unstamped|stale> seed=<seed>
#
# WHY freshness-next EXISTS (order 636-*, windows host 2026-08-09)
# ---------------------------------------------------------------
# The standing FRESHNESS audit class asks each cycle to re-validate "the top
# component the freshness-advisory phase flagged". That phase ranks
# `freshness-stale:` lines by age (local-ci.sh, `sort -t' ' -k3,3nr`), and a
# `freshness-stale:` line is only ever emitted for a file that ALREADY carries a
# stamp. Unstamped files cannot be stale, because staleness is measured from a
# stamp they do not have.
#
# So the audit queue was drawn from the stamped set — 8 files — and re-offered
# those same 8 forever. Every cycle dutifully audited one, re-stamped it, and
# coverage did not move. The measurements say it plainly:
#
#   2026-07-31 audit:   969 components,  8 stamped,  0%
#   2026-08-09 audit:  1021 components,  8 stamped,  0%
#
# Nine days, +52 components, +0 stamps. The class was not slow, it was closed:
# no path existed from "unstamped" to "audited". This script was itself the top
# stale component on both dates, which is how the loop was caught — it was being
# asked to audit itself a second time while a thousand files had never been
# looked at once.
#
# freshness-next: names the next audit target and draws it from the UNSTAMPED set
# first, falling back to the oldest stamped file only when coverage is complete.
# The seed is printed so a cycle can be replayed, and rotates by UTC date so
# consecutive cycles on one host do not re-audit one file.
#
# A `# freshness:` record line looks like (one of):
#   # freshness: auditor=<agent-id> date=<ISO-date> verdict=<refreshed|updated|obsoleted> scope=<one-line>
# The first `# freshness:` line in a file wins.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Canonical staleness threshold — OWNED by methodology.yaml
# component_freshness.canonical_threshold (order 606-vaua). Env override is
# for tests/fixtures only. Stale iff age_days > threshold (boundary = fresh).
THRESHOLD_DAYS="${FRESHNESS_THRESHOLD_DAYS:-$(sed -n '/canonical_threshold:/,/clock_semantics:/p' methodology.yaml 2>/dev/null | grep -m1 'age_days:' | grep -oE '[0-9]+' || true)}"
[ -n "$THRESHOLD_DAYS" ] || THRESHOLD_DAYS=30

# Portable ISO-date -> epoch: GNU `date -d` first, BSD `date -j -f` fallback.
# The GNU-only form silently failed on macOS, so age never computed and NO
# stamp could ever go stale on this host class (606-vaua criterion 2's live
# failure mode).
iso_to_epoch() {
    date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%d' "$1" +%s 2>/dev/null || true
}

# --self-test (606-vaua criterion 4): run the classification against five
# fixtures in a temp inventory — fresh(today), boundary(=threshold),
# stale(threshold+1), malformed date, future date (clock skew) — and assert
# each lands on exactly the right report line. Exercises the REAL script
# recursively with FRESHNESS_FIXTURE_DIR pointing the inventory at fixtures.
if [ "${1:-}" = "--self-test" ]; then
    TDIR="$(mktemp -d)"
    trap 'rm -rf "$TDIR"' EXIT
    today_st="$(date -u +%Y-%m-%d)"
    epoch_today="$(iso_to_epoch "$today_st")"
    day_at_threshold="$(date -u -d "@$((epoch_today - THRESHOLD_DAYS * 86400))" +%Y-%m-%d 2>/dev/null || date -j -u -f '%s' "$((epoch_today - THRESHOLD_DAYS * 86400))" +%Y-%m-%d 2>/dev/null)"
    day_stale="$(date -u -d "@$((epoch_today - (THRESHOLD_DAYS + 1) * 86400))" +%Y-%m-%d 2>/dev/null || date -j -u -f '%s' "$((epoch_today - (THRESHOLD_DAYS + 1) * 86400))" +%Y-%m-%d 2>/dev/null)"
    day_future="$(date -u -d "@$((epoch_today + 5 * 86400))" +%Y-%m-%d 2>/dev/null || date -j -u -f '%s' "$((epoch_today + 5 * 86400))" +%Y-%m-%d 2>/dev/null)"
    printf '# freshness: auditor=selftest date=%s verdict=refreshed scope=fresh fixture\n' "$today_st"      > "$TDIR/fresh.sh"
    printf '# freshness: auditor=selftest date=%s verdict=refreshed scope=boundary fixture\n' "$day_at_threshold" > "$TDIR/boundary.sh"
    printf '# freshness: auditor=selftest date=%s verdict=refreshed scope=stale fixture\n' "$day_stale"     > "$TDIR/stale.sh"
    # 2026-99-99 matches the record grammar's date charset but is not a real
    # date — the stamped-but-unassessable lane. (A fully alphabetic garbage
    # date never matches the stamp grammar at all and counts unstamped.)
    printf '# freshness: auditor=selftest date=2026-99-99 verdict=refreshed scope=malformed fixture\n'      > "$TDIR/malformed.sh"
    printf '# freshness: auditor=selftest date=%s verdict=refreshed scope=future fixture\n' "$day_future"   > "$TDIR/future.sh"
    printf '#!/bin/sh\n'                                                                                    > "$TDIR/unstamped.sh"
    out="$(FRESHNESS_FIXTURE_DIR="$TDIR" "$0")"
    fail=0
    echo "$out" | grep -q  '^freshness-stale: stale.sh '        || { echo "SELFTEST-FAIL: stale fixture not flagged stale"; fail=1; }
    echo "$out" | grep -qv '^freshness-stale: fresh.sh '        || { echo "SELFTEST-FAIL: fresh fixture flagged stale"; fail=1; }
    echo "$out" | grep -q  '^freshness-stale: boundary.sh '     && { echo "SELFTEST-FAIL: boundary fixture flagged stale (must be fresh at exactly threshold)"; fail=1; }
    echo "$out" | grep -q  '^freshness-malformed: malformed.sh' || { echo "SELFTEST-FAIL: malformed date not surfaced"; fail=1; }
    echo "$out" | grep -q  '^freshness-clock-skew: future.sh '  || { echo "SELFTEST-FAIL: future date not surfaced as clock skew"; fail=1; }
    echo "$out" | grep -q  '^freshness-unstamped: unstamped.sh$' || { echo "SELFTEST-FAIL: unstamped fixture not distinct"; fail=1; }
    echo "$out" | grep -qE '^freshness-coverage: [0-9]+\.[0-9]% \(5/6' || { echo "SELFTEST-FAIL: coverage not fractional 5/6"; fail=1; }
    [ "$fail" -eq 0 ] && echo "freshness-selftest: PASS (5 fixtures + unstamped, threshold=${THRESHOLD_DAYS}d)" || exit 1
    exit 0
fi

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
# while-read instead of mapfile: macOS ships bash 3.2 (no mapfile), and the
# litmus runner executes this on every host.
CANDIDATES=()
if [ -n "${FRESHNESS_FIXTURE_DIR:-}" ]; then
    # Self-test fixture mode: inventory exactly the fixture dir.
    cd "$FRESHNESS_FIXTURE_DIR" || exit 2
    while IFS= read -r _cand; do
        CANDIDATES+=("$_cand")
    done < <(find . -type f -name '*.sh' 2>/dev/null | sed 's|^\./||')
else
while IFS= read -r _cand; do
    CANDIDATES+=("$_cand")
done < <(
    # shell scripts + C helpers anywhere under scripts/
    find scripts -type f \( -name '*.sh' -o -name '*.c' \) 2>/dev/null
    for d in "${INVENTORY_PATHS[@]:1}"; do
        [ -d "$d" ] || continue
        find "$d" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.md' \) 2>/dev/null
    done
)
fi

total=0
stamped=0
declare -a STAMP_LINES
declare -a UNSTAMPED_LINES

today="$(date -u +%Y-%m-%d)"

# ONE grep PASS, NOT ONE PER FILE (order 661-*, windows host 2026-08-10).
#
# This loop used to run `grep -m1` against every candidate — 1026 process
# spawns. On Linux that is cheap enough to go unnoticed; on Windows, where
# process creation is expensive, the full run took **126.8 seconds** and even
# the two-line header took 23.2s, blowing litmus:freshness-inventory-shape's
# 15s step timeout. The test failed on this host for a host-performance reason
# with nothing wrong in its behaviour — and it had been failing invisibly,
# because until this cycle nobody had run the suite here.
#
# Almost every candidate is UNSTAMPED (1018 of 1026), so almost every one of
# those spawns was asking a question whose answer was "no". One `grep -l` pass
# names the few files that carry a stamp; only those are then parsed
# individually, exactly as before. 1026 spawns -> 1 + 8.
#
# Semantics are unchanged by construction: a file absent from the list has no
# matching line, which is precisely the old `grep -m1` empty result, and a file
# present is parsed with the same expression and the same first-match-wins rule.
STAMPED_SET=""
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
    STAMPED_SET="$(printf '%s\n' "${CANDIDATES[@]}" \
        | tr '\n' '\0' \
        | xargs -0 grep -lE "$STAMP_RE" 2>/dev/null || true)"
fi

for f in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    # Only count files that exist and are regular files.
    [ -f "$f" ] || continue
    total=$((total + 1))
    rel="${f#./}"
    # Find the first freshness record in the file — but only for files the
    # single pass above already proved carry one.
    rec=""
    case "
$STAMPED_SET
" in
        *"
$f
"*) rec="$(grep -m1 -E "$STAMP_RE" "$f" 2>/dev/null || true)" ;;
    esac
    if [[ -n "$rec" ]]; then
        if [[ "$rec" =~ $STAMP_RE ]]; then
            auditor="${BASH_REMATCH[2]}"
            fdate="${BASH_REMATCH[3]}"
            verdict="${BASH_REMATCH[4]}"
            stamped=$((stamped + 1))
            STAMP_LINES+=("$rel|$verdict|$fdate|$auditor")
            # Age in UTC whole days per methodology
            # component_freshness.canonical_threshold clock_semantics:
            # stale iff age > threshold; future dates clamp to 0 but are
            # surfaced as clock skew; unparseable dates are surfaced as
            # malformed (stamped-but-unassessable), never silently aged.
            fdate_day="${fdate:0:10}"
            if [[ "$fdate_day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                ts_stamp="$(iso_to_epoch "$fdate_day")"
                ts_today="$(iso_to_epoch "$today")"
                if [[ -n "$ts_stamp" && -n "$ts_today" ]]; then
                    age_days=$(( (ts_today - ts_stamp) / 86400 ))
                    if [[ $age_days -lt 0 ]]; then
                        printf 'freshness-clock-skew: %s %s (future-dated; clamped fresh)\n' "$rel" "$fdate_day"
                        age_days=0
                    fi
                    if [[ $age_days -gt $THRESHOLD_DAYS ]]; then
                        printf 'freshness-stale: %s %s %s %s\n' "$rel" "$age_days" "$verdict" "$fdate"
                    fi
                else
                    printf 'freshness-malformed: %s %s (date did not convert)\n' "$rel" "$fdate_day"
                fi
            else
                printf 'freshness-malformed: %s %s (not ISO-8601)\n' "$rel" "$fdate"
            fi
        fi
    else
        UNSTAMPED_LINES+=("$rel")
    fi
done

unstamped=$((total - stamped))
# Truthful fractional coverage (606-vaua criterion 3): 7/1011 must render as
# 0.7%, not 0%. One decimal via awk (POSIX; no bash float). Numerator and
# denominator ride the line, plus a cycle-over-cycle delta from the per-host
# cache (target/ is untracked; first run reports delta=unknown).
if [[ $total -gt 0 ]]; then
    pct="$(awk -v s="$stamped" -v t="$total" 'BEGIN { printf "%.1f", (s * 100.0) / t }')"
else
    pct="0.0"
fi
delta="unknown"
CACHE="target/freshness-inventory.last"
if [ -z "${FRESHNESS_FIXTURE_DIR:-}" ]; then
    if [ -f "$CACHE" ]; then
        last_stamped="$(cut -d' ' -f1 "$CACHE" 2>/dev/null)"
        case "$last_stamped" in
            ''|*[!0-9]*) : ;;
            *) d=$((stamped - last_stamped)); [ "$d" -ge 0 ] && delta="+$d" || delta="$d" ;;
        esac
    fi
    mkdir -p target 2>/dev/null && printf '%s %s\n' "$stamped" "$today" > "$CACHE" 2>/dev/null || true
fi

echo "freshness-inventory: $total components, $stamped stamped, $unstamped unstamped"
echo "freshness-coverage: ${pct}% (${stamped}/${total} delta=${delta})"
for line in "${STAMP_LINES[@]:-}"; do
    [ -z "$line" ] && continue
    IFS='|' read -r rel verdict fdate auditor <<< "$line"
    echo "freshness-stamp: $rel $verdict $fdate $auditor"
done
for rel in "${UNSTAMPED_LINES[@]:-}"; do
    [ -z "$rel" ] && continue
    echo "freshness-unstamped: $rel"
done

# --- next audit target -------------------------------------------------------
# Unstamped first: at 0% coverage the stamped set is not a sample of the system,
# it is a sample of what previous audits happened to touch. Ranking within it
# answers "which of the 8 files we have looked at is oldest", which is not the
# question the audit class is asking.
FRESHNESS_SEED="${FRESHNESS_SEED:-$(date -u +%Y%m%d)}"
next_rel=""
next_src=""

if [ "${#UNSTAMPED_LINES[@]}" -gt 0 ] && [ -n "${UNSTAMPED_LINES[0]:-}" ]; then
    # Deterministic rotation: same seed + same inventory -> same target, so a
    # cycle is replayable, while consecutive days advance through the backlog.
    n="${#UNSTAMPED_LINES[@]}"
    idx="$(printf '%s' "$FRESHNESS_SEED" | cksum | cut -d' ' -f1)"
    idx=$((idx % n))
    next_rel="${UNSTAMPED_LINES[$idx]}"
    next_src="unstamped"
elif [ "${#STAMP_LINES[@]}" -gt 0 ] && [ -n "${STAMP_LINES[0]:-}" ]; then
    # Coverage is complete — fall back to the oldest stamp.
    next_rel="$(for line in "${STAMP_LINES[@]}"; do
        [ -z "$line" ] && continue
        IFS='|' read -r rel _verdict fdate _auditor <<< "$line"
        printf '%s %s\n' "$fdate" "$rel"
    done | sort | head -1 | cut -d' ' -f2)"
    next_src="stale"
fi

if [ -n "$next_rel" ]; then
    echo "freshness-next: $next_rel source=$next_src seed=$FRESHNESS_SEED"
fi

exit 0
