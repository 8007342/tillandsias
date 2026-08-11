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
