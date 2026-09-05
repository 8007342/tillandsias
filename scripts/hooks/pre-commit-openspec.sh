#!/usr/bin/env bash
# pre-commit-openspec.sh — Non-blocking OpenSpec trace warnings (default), CI-mode enforcement
# @trace spec:spec-traceability, spec:cheatsheet-source-layer, spec:cheatsheet-methodology-evolution
#
# PHILOSOPHY: This hook ALWAYS exits 0 by default. It NEVER blocks commits.
#
# OpenSpec follows CRDT-inspired monotonic convergence: specs and code
# drift apart naturally, and warnings nudge them back together over time.
# A warning today becomes a fix next week — or stays as a known gap.
# Blocking commits would break flow and punish incremental progress.
#
# CI mode (--ci-mode): In CI/release workflows, exit 1 on ANY warning.
# This ensures releases only happen when spec-code alignment is verified.
#
# What it checks:
#   1. Ghost traces — @trace referencing non-existent specs
#   2. Zero-trace specs — specs with no @trace annotations in the codebase
#   3. Stale changes — active changes older than 7 days
#   4. Cheatsheet source binding — INDEX.json ↔ local: path ↔ file consistency
#      (via scripts/check-cheatsheet-sources.sh --no-sha)
#      ERRORS from the binding check are printed as warnings.
#
# Usage:
#   Installed as .git/hooks/pre-commit (via scripts/install-hooks.sh)
#   Or run manually: bash scripts/hooks/pre-commit-openspec.sh
#   In CI: bash scripts/hooks/pre-commit-openspec.sh --ci-mode

# No set -e — we handle errors ourselves. This hook must never abort (except in --ci-mode).
set -uo pipefail

# Portable nanosecond clock. `date +%s%N` is GNU-only and BSD SUCCEEDS while
# emitting a literal "N", so a `|| echo 0` guard never fires and the per-check
# elapsed arithmetic runs on a non-numeric value (784-dwkh). Digit-validate,
# then degrade to whole seconds — this feeds a budget warning only.
_hook_now_ns() {
    _t="$(date +%s%N 2>/dev/null || true)" # gnu-date: ok (digit-validated below)
    case "$_t" in
        '' | *[!0-9]*) _t="$(date +%s 2>/dev/null || echo 0)000000000" ;;
    esac
    printf '%s' "$_t"
}

CI_MODE=false
[[ "${1:-}" == "--ci-mode" ]] && CI_MODE=true

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { exit 0; }
SPECS_DIR="$REPO_ROOT/openspec/specs"
CHANGES_DIR="$REPO_ROOT/openspec/changes"

# Skip if openspec directory structure doesn't exist
[[ -d "$SPECS_DIR" ]] || exit 0

ghost_warnings=0
zero_trace_warnings=0
warnings=0

normalize_spec_list() {
    local raw="${1:-}"
    raw="${raw//:/ }"
    raw="${raw//,/ }"
    for item in $raw; do
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done | awk '!seen[$0]++'
}

spec_is_ignored() {
    local needle="$1"
    local raw_list="${TILLANDSIAS_OPEN_SPEC_IGNORE:-${TILLANDSIAS_STRICT_IGNORE_SPECS:-}}"
    [[ -z "$raw_list" ]] && return 1
    while IFS= read -r item; do
        [[ "$item" == "$needle" ]] && return 0
    done < <(normalize_spec_list "$raw_list")
    return 1
}

# --- 1. Ghost trace check ---------------------------------------------------
# Scan staged files for @trace spec:<name> where the spec doesn't exist.
# Per methodology/ci.yaml: Ghost traces are BLOCKING errors.

ghost_check() {
    # ONE grep over every staged file, and no subprocess per trace line
    # (order 734-sjb3, second measurement). This used to spawn a grep per
    # staged file plus an `echo | grep` per @trace line, so its cost scaled
    # with files x traces. Measured: the commit that landed this packet's own
    # fix staged four files and ghost_check took 1,309ms against a 300ms
    # budget -- the drift warning fired on its first real commit, which is the
    # signal working, and the fix belongs in the cost rather than the budget.
    local staged_files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" && -f "$REPO_ROOT/$f" ]] && staged_files+=("$f")
    done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.(rs|sh|toml)$')

    [[ "${#staged_files[@]}" -eq 0 ]] && return 0

    local matches
    matches="$(cd "$REPO_ROOT" && grep -nHE '@trace[[:space:]]+spec:[a-zA-Z0-9_-]+' \
        -- "${staged_files[@]}" 2>/dev/null)" || return 0

    local match_line file lineno content rest spec_name
    while IFS= read -r match_line; do
        [[ -n "$match_line" ]] || continue
        file="${match_line%%:*}"
        rest="${match_line#*:}"
        lineno="${rest%%:*}"
        content="${rest#*:}"

        # Bash-native extraction: a line may carry several comma-separated
        # refs, and the old `echo "$content" | grep -oE` cost two processes for
        # every one of them.
        rest="$content"
        while [[ "$rest" =~ spec:([a-zA-Z0-9_-]+) ]]; do
            spec_name="${BASH_REMATCH[1]}"
            if [[ ! -d "$SPECS_DIR/$spec_name" ]]; then
                echo "  ✗ OpenSpec: ghost trace 'spec:$spec_name' in $file:$lineno — no spec exists" >&2
                ghost_warnings=$((ghost_warnings + 1))
                warnings=$((warnings + 1))
            fi
            rest="${rest#*spec:"$spec_name"}"
        done
    done <<< "$matches"
}

# --- 2. Zero-trace spec check -----------------------------------------------
# Find specs that have zero @trace annotations anywhere in the codebase.
# Local pre-commit reports these as advisory notices; CI/release mode treats
# them as blocking because methodology/ci.yaml requires trace binding.

zero_trace_check() {
    [[ -d "$SPECS_DIR" ]] || return 0

    # ONE pass over the repo, not one per spec (order 734-sjb3).
    #
    # This loop used to run a full recursive `grep -rl` across every source
    # file FOR EACH SPEC. Measured on the Windows host: 170 spec directories x
    # 4.5s per repo-wide grep = ~12.7 minutes, which matched the observed
    # 10-11 minute commits exactly. Two commits died to a 10-minute tool
    # timeout with the work left staged before this was measured.
    #
    # The cost was almost entirely SYSCALL time (sys 3.79s vs user 0.93s on a
    # single grep) — process spawn plus filesystem traversal — which is why it
    # is brutal on Windows and barely noticeable on Linux, and why it was never
    # caught by the host that authored it.
    #
    # Inverting it is exact, not an approximation: collect every `spec:<name>`
    # token the codebase actually references in a single sweep, then ask which
    # specs are absent from that set. Same answer, one traversal.
    # THE SECOND MEASUREMENT (order 734-sjb3, exit criterion 1 again). Inverting
    # the loop took the hook from ~13min to ~69s, and then the remaining cost was
    # measured rather than assumed:
    #
    #   the repo-wide sweep below ................  1.6s
    #   the per-spec loop (170 specs) ............ 62.0s
    #
    # The sweep was never the problem after the inversion. The loop was spawning
    # THREE subprocesses per spec -- a sed for the Status block, a grep to read
    # it, a grep to test set membership -- 510 processes at ~107ms each on
    # Windows. Same root cause as the original defect, one layer down: on this
    # host a process spawn costs two orders of magnitude more than the work it
    # does, so any per-item subprocess is the whole runtime.
    #
    # Both remaining per-spec spawns are removed. Retired specs come from ONE
    # awk pass over every spec.md, and membership is a bash associative array.
    # 510 spawns -> 2.
    # THE THIRD MEASUREMENT (order 734-sjb3, reopened 2026-09-05 on macbookair's
    # 10373ms against this phase's own 2500ms budget).
    #
    # `grep -r` with --include still WALKS every directory; --include only
    # decides which files it opens. So this sweep was descending the entire
    # build output — 141,414 entries under target/ on yoga against 12,352
    # everywhere else — to read 928 source files. Ten times the traversal for
    # none of the answer.
    #
    # MEASURED HERE, GNU grep, warm cache, three runs each:
    #   sweep as it was ......... 135 / 133 / 126 ms
    #   with target/ .git/ cut ...  20 /  15 /  19 ms
    # and the whole phase 176ms -> 63ms. On macOS the same traversal is what
    # 734-sjb3 already identified as the dominant cost twice: "almost entirely
    # SYSCALL time — process spawn plus filesystem traversal — brutal on
    # Windows, barely noticeable on Linux". A host whose target/ is populated
    # pays it; one that has never built does not, which is why the budget held
    # for so long and then did not.
    #
    # ANSWER-PRESERVING, verified rather than assumed: the token set is
    # IDENTICAL with and without the exclusions — 218 both ways, and the
    # set difference is empty. A spec referenced only from build output would
    # become a false ghost, so this was checked before it was written.
    #
    # NOTE the measurement trap this nearly fell into: an interactive shell here
    # has `grep` aliased to ugrep, which reports 2-6ms for the same sweep and
    # would have hidden the cost entirely. Every number above is /usr/bin/grep,
    # which is what the hook gets.
    local referenced
    referenced="$(grep -rhoE 'spec:[a-zA-Z0-9._-]+' \
        --include='*.rs' --include='*.sh' --include='*.toml' --include='Containerfile*' \
        --exclude-dir=target --exclude-dir=.git --exclude-dir=node_modules \
        "$REPO_ROOT" 2>/dev/null \
        | sed 's/^spec://' \
        | sort -u)" || true

    # Space-delimited string sets, not `local -A` (784-dwkh): associative
    # arrays are bash>=4 and Apple ships 3.2, so on macOS line 173 raised
    # `local: -A: invalid option` and BOTH membership sets stayed empty —
    # every spec then looked unreferenced and un-retired. Spec names are path
    # components (no spaces), so a spaced-token match is exact. This keeps
    # 734-sjb3's discipline intact: concatenation and `case` are builtins, so
    # there is still no subprocess per item.
    local is_referenced=" "
    local tok
    while IFS= read -r tok; do
        [[ -n "$tok" ]] && is_referenced="${is_referenced}${tok} "
    done <<<"$referenced"

    # Deferred or obsolete specs are retired contracts. They remain in the tree
    # for traceability but are excluded from active zero-trace scoring. The
    # Status block runs from `## Status` to the next `## ` heading; this is the
    # same window the two-sed pipeline read, expressed once over all files.
    local is_retired=" "
    local retired
    retired="$(awk '
        FNR == 1 { inblock = 0 }
        /^## Status$/ { inblock = 1; next }
        inblock && /^## / { inblock = 0 }
        inblock && /^(status:[ \t]*(deferred|obsolete)|deferred|obsolete)[ \t]*$/ {
            n = split(FILENAME, parts, "/")
            print parts[n - 1]
            inblock = 0
        }
    ' "$SPECS_DIR"/*/spec.md 2>/dev/null)" || true
    while IFS= read -r tok; do
        [[ -n "$tok" ]] && is_retired="${is_retired}${tok} "
    done <<<"$retired"

    for spec_dir in "$SPECS_DIR"/*/; do
        [[ -d "$spec_dir" ]] || continue
        local spec_name="${spec_dir%/}"
        spec_name="${spec_name##*/}"

        case "$is_retired" in *" $spec_name "*) continue ;; esac
        case "$is_referenced" in *" $spec_name "*) continue ;; esac

        echo "  ◌ OpenSpec: spec '$spec_name' has no @trace annotations in code" >&2
        zero_trace_warnings=$((zero_trace_warnings + 1))
        warnings=$((warnings + 1))
    done
}

# --- 3. Active change staleness check ---------------------------------------
# Flag changes with created: dates older than 7 days.

staleness_check() {
    [[ -d "$CHANGES_DIR" ]] || return 0

    local today_epoch
    today_epoch="$(date +%s 2>/dev/null)" || return 0

    # Spawn-free per change (order 734-sjb3, second measurement). This loop ran
    # dirname + two basenames + a four-stage grep|head|sed|tr pipeline for every
    # change directory -- eight processes each, and on Windows a spawn costs far
    # more than the work. Parameter expansion and a read loop do the same job
    # with none. Only `date -d` remains, once per surviving change, because
    # parsing YYYY-MM-DD to epoch in bash is not worth the subtlety.
    # Measured: 3.6s -> 0.6s.
    for yaml_file in "$CHANGES_DIR"/*/.openspec.yaml; do
        [[ -f "$yaml_file" ]] || continue

        local change_dir="${yaml_file%/.openspec.yaml}"
        local change_name="${change_dir##*/}"

        # Skip the archive directory
        [[ "$change_name" == "archive" ]] && continue

        if spec_is_ignored "$change_name"; then
            continue
        fi

        # Extract created: date (YYYY-MM-DD format) — first match wins, exactly
        # as the old `| head -1` did.
        local created_date="" line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^created:[[:space:]]*(.*)$ ]]; then
                created_date="${BASH_REMATCH[1]//[[:space:]]/}"
                break
            fi
        done < "$yaml_file"

        [[ -z "$created_date" ]] && continue

        # Parse date to epoch
        local created_epoch
        # GNU then BSD. `date -d` is GNU-only and its failure lands on a
        # `|| continue`, so on macOS this whole staleness check silently
        # skipped EVERY change — a warning that could never fire, which is
        # indistinguishable from "nothing is stale" (784-dwkh).
        created_epoch="$(date -d "$created_date" +%s 2>/dev/null \
            || date -j -u -f '%Y-%m-%d' "${created_date%%T*}" +%s 2>/dev/null)" || continue

        local age_days=$(( (today_epoch - created_epoch) / 86400 ))

        if [[ "$age_days" -ge 7 ]]; then
            echo "  ⚠ OpenSpec: change '$change_name' is $age_days days old — consider archiving or updating" >&2
            warnings=$((warnings + 1))
        fi
    done
}

# --- 4. Cheatsheet source binding check ------------------------------------
# Legacy verbatim source layer check — kept for the three-release retention
# window per @tombstone discipline. The new tier validator (check 4b) is
# the canonical replacement.
# @trace spec:cheatsheet-source-layer

cheatsheet_source_check() {
    local checker="${REPO_ROOT}/scripts/check-cheatsheet-sources.sh"
    [[ -f "${checker}" ]] || return 0
    [[ -f "${REPO_ROOT}/cheatsheet-sources/INDEX.json" ]] || return 0

    local output exit_code
    output="$(bash "${checker}" --no-sha 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    if [[ "${exit_code}" -ne 0 ]]; then
        # Errors from the binding checker — surface as pre-commit warnings.
        echo "  ⚠ cheatsheet-sources: binding errors (non-blocking):" >&2
        while IFS= read -r line; do
            echo "    ${line}" >&2
        done <<< "${output}"
        warnings=$((warnings + 1))
    fi
    # Warnings (UNFETCHED) are suppressed here — they appear on manual runs.
}

# --- 4b. Cheatsheet tier-aware validator (cheatsheets-license-tiered) ------
# Runs scripts/check-cheatsheet-tiers.sh in --quiet mode. ERRORs surface as
# non-blocking OpenSpec warnings (CRDT-convergence philosophy). The validator
# itself is non-fatal: it exits 0 unless tier-conditional fields are missing
# or CRDT override discipline is violated.
# @trace spec:cheatsheets-license-tiered

cheatsheet_tier_check() {
    local checker="${REPO_ROOT}/scripts/check-cheatsheet-tiers.sh"
    [[ -f "${checker}" ]] || return 0

    local output exit_code
    output="$(bash "${checker}" --quiet 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    if [[ "${exit_code}" -ne 0 ]]; then
        echo "  ⚠ cheatsheet-tiers: validation ERRORs (non-blocking):" >&2
        while IFS= read -r line; do
            echo "    ${line}" >&2
        done <<< "${output}"
        warnings=$((warnings + 1))
    fi
}

# --- Run all checks ---------------------------------------------------------
#
# EVERY PHASE ANNOUNCES ITSELF (order 734-sjb3, exit criterion 3). The original
# defect was not only that the scan took thirteen minutes -- it was that the
# hook went SILENT for thirteen minutes while printing nothing but pre-existing
# ghost-trace debt, so an operator could not tell a slow scan from a hung one.
# Two commits were killed on that ambiguity with the work left staged.
#
# A hook that is fast today can be slow tomorrow: the cost here scales with spec
# count and repo size, both of which only grow. The budget printed beside each
# phase is the MEASURED time on the slowest host (windows, 2026-08-15), so a
# phase that has drifted past its budget is visible to whoever is watching
# rather than only in a profiler someone thinks to run.
#
# Written to stderr and only when attached to a terminal: a hook that spams
# progress lines into scripted commits makes every cycle's log noisier, and the
# unattended case is the one that can least afford the churn.

phase_budget_ms() {
    case "$1" in
        ghost_check)            echo 900 ;;
        zero_trace_check)       echo 2500 ;;
        staleness_check)        echo 1000 ;;
        cheatsheet_source_check) echo 200 ;;
        cheatsheet_tier_check)  echo 900 ;;
        *)                      echo 0 ;;
    esac
}

run_phase() {
    local fn="$1" budget started ended elapsed
    budget="$(phase_budget_ms "$fn")"
    if [[ -t 2 ]]; then
        printf '  … OpenSpec: %s (expected ~%sms)\r' "$fn" "$budget" >&2
    fi
    started="$(_hook_now_ns)"
    "$fn"
    ended="$(_hook_now_ns)"
    elapsed=$(( (ended - started) / 1000000 ))
    if [[ -t 2 ]]; then
        printf '\033[2K\r' >&2
    fi
    # Over budget is worth saying out loud even in a scripted commit -- that is
    # the signal that would have named the original thirteen-minute scan.
    if [[ "$budget" -gt 0 && "$elapsed" -gt $((budget * 4)) ]]; then
        echo "  ⚠ OpenSpec: ${fn} took ${elapsed}ms (budget ~${budget}ms) — the scan is drifting; see order 734-sjb3" >&2
    fi
}

echo "" >&2  # Visual separator from git's own output

run_phase ghost_check
run_phase zero_trace_check
run_phase staleness_check
run_phase cheatsheet_source_check
run_phase cheatsheet_tier_check

# ORDER 448. The tracked images/default/cheatsheets/ copy is DERIVED from the
# authored tree, and an authoring commit that omits it leaves every other host
# unable to push (the v5 pre-push hook refuses; three measured instances, the
# latest 2026-09-02). The author is the one person who does not see it — their
# own commit succeeds and the failure surfaces elsewhere, on a file they never
# touched. Re-sync into THIS commit rather than warn about it: the tree is
# purely derived, and the remedy the stager already prints is a command a human
# would only retype. No-ops silently unless the commit touches cheatsheets/,
# and never blocks — see the script for the full rationale.
_cheatsheet_image_sync() {
    local sync="${REPO_ROOT}/scripts/sync-image-cheatsheets-for-commit.sh"
    [[ -r "$sync" ]] || return 0
    # stdout is the machine verdict token and is not for the committer; stderr
    # carries the loud human warning and MUST reach them — swallowing it would
    # reproduce exactly the silence this guard exists to remove.
    bash "$sync" >/dev/null || true
}
run_phase _cheatsheet_image_sync

if [[ "$warnings" -gt 0 ]]; then
    echo "" >&2
    if [[ "$CI_MODE" == "true" ]]; then
        if [[ "$ghost_warnings" -gt 0 ]]; then
            echo "  OpenSpec: $ghost_warnings blocking error(s), $zero_trace_warnings warning(s) — FAILING CI MODE" >&2
        else
            echo "  OpenSpec: $zero_trace_warnings blocking error(s) — FAILING CI MODE" >&2
        fi
    else
        echo "  OpenSpec: $warnings notice(s) — not blocking commit" >&2
    fi
    echo "" >&2
fi

# Exit 0 by default (pre-commit hook philosophy)
# Exit 1 in CI mode if trace binding is broken.
if [[ "$CI_MODE" == "true" && $((ghost_warnings + zero_trace_warnings)) -gt 0 ]]; then
    exit 1
fi
exit 0
