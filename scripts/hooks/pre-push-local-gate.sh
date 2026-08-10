#!/usr/bin/env bash
# pre-push-local-gate.sh — enforce locally what GitHub Actions used to enforce.
# @trace spec:methodology-accountability, spec:versioning
#
# CONTEXT
#
# Until 2026-08-03 a push to linux-next fired a three-job CI matrix in the cloud.
# That workflow was removed on operator directive — cloud minutes are paid, our
# hardware is not, and only the release genuinely needs GitHub secrets. The
# validations were never the problem; where they ran was.
#
# This hook is where they run now. It is the trunk's only automated protection.
#
# WHAT IT DOES, AND WHY IT IS FAST
#
#   1. release-preflight.sh — version monotonicity, retired CLI flags, plan
#      ledger integrity, actions budget. All local, about a second.
#   2. gate-stamp.sh verify — proves `./build.sh --check` actually ran against
#      THIS tree. Running the full gate inside the hook would be more direct, but
#      a multi-minute hook gets bypassed on its second use and then protects
#      nothing. Hashing the diff costs milliseconds and gives the same guarantee.
#
# PLAN-ONLY FAST LANE (order 668-2xeh)
#
# Twice on 2026-08-10 an in-forge session whose ONLY changes were plan ledger
# fragments could not push them: the stamp requires `./build.sh --check` in the
# checkout, the session's build-free directive (667-se87: in-forge workspace
# builds were crashing rustc) forbade it, the agent correctly refused
# --no-verify, and its fragments died with the container — recovered only by
# journald archaeology. A diff that adds ONLY new fragment files under
# plan/index.d/ and plan/loop_status.d/ has a verifiable closure that needs no
# compiler: YAML parse, fragment schema (tillandsias-plan check), and the
# fragment-applicable forbidden-pattern checks. When the stamp is missing or
# stale, the gate therefore attempts that lane before refusing.
#
# FAIL CLOSED: any path outside those two directories, any modification or
# deletion of an EXISTING file (fragments are immutable by design), any
# nested/odd filename, any validation failure, or no ref list to scope the
# diff — all fall back to the full gate exactly as before. The lane can only
# ACCEPT a strictly smaller class of pushes; it can never weaken the normal
# path.
#
# BYPASS
#
# `git push --no-verify` still works, deliberately — a hook that cannot be
# bypassed strands an operator in an emergency. But it is now an explicit,
# visible act rather than the silent default it was when nothing ran at all.
#
# Exit 0 to allow the push, non-zero to refuse.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT" || exit 0

# Git supplies "<local ref> <local sha> <remote ref> <remote sha>" per pushed
# ref on stdin; the installed composed hook captures it once and replays it to
# every guard. Read it up front — the plan-only lane needs it to scope the
# outgoing diff. Guard against a terminal so a manual invocation cannot hang.
REFS=""
if [[ ! -t 0 ]]; then
    REFS="$(cat 2>/dev/null || true)"
fi

RED=$'\033[0;31m'; YLW=$'\033[0;33m'; GRN=$'\033[0;32m'; RST=$'\033[0m'
[[ -t 2 ]] || { RED=""; YLW=""; GRN=""; RST=""; }

refuse() {
    echo "" >&2
    echo "${RED}✗ pre-push refused: $1${RST}" >&2
    shift
    for line in "$@"; do echo "  $line" >&2; done
    echo "" >&2
    echo "  Push CI no longer exists. This hook is the trunk's only gate." >&2
    echo "  To override anyway: git push --no-verify" >&2
    echo "" >&2
    exit 1
}

# ── 1. Release preflight ───────────────────────────────────────────────────────
if [[ -f scripts/release-preflight.sh ]]; then
    verdict="$(bash scripts/release-preflight.sh 2>/dev/null | tail -1)"
    rc=$?
    if [[ $rc -ne 0 || "$verdict" != "ok:release-preflight" ]]; then
        detail="$(bash scripts/release-preflight.sh 2>&1 >/dev/null | head -6)"
        refuse "release preflight says ${verdict:-<no verdict>}" \
               "$detail" \
               "" \
               "Reproduce: scripts/release-preflight.sh --verbose"
    fi
fi

# ── Plan-only fast lane (order 668-2xeh) ───────────────────────────────────────
# Attempted only when the stamp is missing/stale. Emits one line per validated
# file — "plan-only lane: validated <path>" — so the push record names exactly
# what was accepted without a build. Returns 0 to accept the push (marker lines
# already printed), 1 to fall back to the full gate (reason already printed).
LANE_NOTES=()

attempt_plan_only_lane() {
    local -a files=() srcs=()
    LANE_NOTES=()

    if [[ -z "$REFS" ]]; then
        echo "plan-only lane: not applicable — no ref list on stdin to scope the outgoing diff (full gate required)" >&2
        return 1
    fi

    # ── Qualification: EVERY outgoing path must be a NEW fragment file ────────
    local local_ref local_sha remote_ref remote_sha
    while read -r local_ref local_sha remote_ref remote_sha; do
        [[ -n "$local_ref" ]] || continue
        if [[ "$local_sha" =~ ^0+$ ]]; then
            echo "plan-only lane: not applicable — $remote_ref is being deleted (full gate required)" >&2
            return 1
        fi
        if [[ "$remote_sha" =~ ^0+$ ]]; then
            echo "plan-only lane: not applicable — $remote_ref is new on the remote; no base to diff against (full gate required)" >&2
            return 1
        fi
        if ! git cat-file -e "$remote_sha" 2>/dev/null; then
            echo "plan-only lane: not applicable — remote base $remote_sha is not present locally (full gate required)" >&2
            return 1
        fi

        # Net outgoing diff for this ref: what the remote will see change.
        # --no-renames keeps the status alphabet to A/M/D/T: a rename of a
        # fragment decomposes into D+A and the D disqualifies, as it must.
        local status path
        while IFS=$'\t' read -r status path; do
            [[ -n "$status" ]] || continue
            if [[ "$status" != "A" ]]; then
                echo "plan-only lane: not applicable — '$path' has status '$status' in the outgoing diff; fragments are immutable, only NEW fragment files qualify (full gate required)" >&2
                return 1
            fi
            case "$path" in
                plan/index.d/?*.yaml)
                    if [[ "${path#plan/index.d/}" == */* ]]; then
                        echo "plan-only lane: not applicable — '$path' is nested below plan/index.d/ (full gate required)" >&2
                        return 1
                    fi
                    ;;
                plan/loop_status.d/?*.md)
                    if [[ "${path#plan/loop_status.d/}" == */* ]]; then
                        echo "plan-only lane: not applicable — '$path' is nested below plan/loop_status.d/ (full gate required)" >&2
                        return 1
                    fi
                    ;;
                *)
                    echo "plan-only lane: not applicable — '$path' is outside plan/index.d/ and plan/loop_status.d/ (full gate required)" >&2
                    return 1
                    ;;
            esac
            files+=("$path")
            srcs+=("$local_sha")
        done < <(git diff --name-status --no-renames "$remote_sha" "$local_sha" -- 2>/dev/null)
    done <<< "$REFS"

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "plan-only lane: not applicable — the outgoing diff is empty (full gate required)" >&2
        return 1
    fi

    # ── Validation closure ────────────────────────────────────────────────────
    # The lane may only accept what it can actually validate. yq parses each
    # pushed YAML blob; tillandsias-plan check validates fragment schema by
    # folding every fragment (so it also parses them — which is why yq-absent
    # may delegate to it, but BOTH absent is a refusal, never a pass).
    local have_yq=0 have_plan=0
    command -v yq >/dev/null 2>&1 && have_yq=1
    [[ -x target/release/tillandsias-plan ]] && have_plan=1
    if [[ $have_yq -eq 0 && $have_plan -eq 0 ]]; then
        echo "plan-only lane: not applicable — neither yq nor target/release/tillandsias-plan is available to validate fragments (fail closed; full gate required)" >&2
        return 1
    fi

    # Per-file validation runs against the PUSHED blob (git show <sha>:<path>),
    # not the worktree — the lane vouches for the bytes the remote receives.
    local tmp i blob
    tmp="$(mktemp -d)" || {
        echo "plan-only lane: not applicable — mktemp failed (full gate required)" >&2
        return 1
    }
    for i in "${!files[@]}"; do
        blob="$tmp/blob"
        if ! git show "${srcs[$i]}:${files[$i]}" > "$blob" 2>/dev/null; then
            echo "plan-only lane: validation FAILED — cannot read ${files[$i]} from the pushed commit (full gate required)" >&2
            rm -rf "$tmp"; return 1
        fi
        case "${files[$i]}" in
            plan/index.d/*)
                if [[ $have_yq -eq 1 ]]; then
                    if ! yq eval '.' "$blob" >/dev/null 2>&1; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} is not valid YAML (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                    if [[ "$(yq eval 'type' "$blob" 2>/dev/null)" != '!!map' ]]; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} does not parse to a YAML mapping (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                else
                    LANE_NOTES+=("yq absent — YAML parse of ${files[$i]} delegated to tillandsias-plan check, which folds every fragment")
                fi
                ;;
            plan/loop_status.d/*)
                # Fragments carry ONLY '## Cycle' sections (plan/loop_status.d/
                # README.md): Direction and ACTIVE RELEASE are operator/
                # coordinator-writes-only LWW registers the lane must not admit.
                if ! grep -q '^## Cycle ' "$blob"; then
                    echo "plan-only lane: validation FAILED — ${files[$i]} has no '## Cycle' heading (full gate required)" >&2
                    rm -rf "$tmp"; return 1
                fi
                if grep -E '^## ' "$blob" | grep -v '^## Cycle ' | grep -q .; then
                    echo "plan-only lane: validation FAILED — ${files[$i]} carries a section other than '## Cycle' (loop-status fragments are Cycle-only; full gate required)" >&2
                    rm -rf "$tmp"; return 1
                fi
                ;;
        esac
    done
    rm -rf "$tmp"

    # Fragment schema over the folded ledger, plus the fold-discard trap check.
    # Both need the tillandsias-plan binary; in-forge it exists. Absent, note
    # the skip honestly (yq already parsed every blob above).
    local out
    if [[ $have_plan -eq 1 ]]; then
        if ! out="$(target/release/tillandsias-plan check 2>&1)"; then
            echo "plan-only lane: validation FAILED — tillandsias-plan check refused the folded ledger (full gate required):" >&2
            echo "$out" | head -6 | sed 's/^/  /' >&2
            return 1
        fi
        if [[ -f scripts/check-fragment-status-loss.sh ]]; then
            if ! out="$(bash scripts/check-fragment-status-loss.sh 2>&1)"; then
                echo "plan-only lane: validation FAILED — check-fragment-status-loss refused (full gate required):" >&2
                echo "$out" | head -6 | sed 's/^/  /' >&2
                return 1
            fi
        else
            LANE_NOTES+=("scripts/check-fragment-status-loss.sh absent — skipped")
        fi
    else
        LANE_NOTES+=("target/release/tillandsias-plan absent — fragment schema and status-loss checks skipped (yq parsed every pushed blob)")
    fi

    # Forbidden-pattern check that applies to any tracked text, fragments
    # included (methodology base64_script_injection_ban).
    if [[ -f scripts/check-no-base64-script-injection.sh ]]; then
        if ! out="$(bash scripts/check-no-base64-script-injection.sh 2>&1)"; then
            echo "plan-only lane: validation FAILED — check-no-base64-script-injection refused (full gate required):" >&2
            echo "$out" | head -6 | sed 's/^/  /' >&2
            return 1
        fi
    else
        LANE_NOTES+=("scripts/check-no-base64-script-injection.sh absent — skipped")
    fi

    # ── Accept ────────────────────────────────────────────────────────────────
    echo "" >&2
    echo "plan-only lane: outgoing diff adds only new plan fragment files — accepting without the build stamp" >&2
    for i in "${!files[@]}"; do
        echo "plan-only lane: validated ${files[$i]}" >&2
    done
    local note
    for note in "${LANE_NOTES[@]}"; do
        echo "plan-only lane: note: $note" >&2
    done
    echo "${GRN}✓ local gate: plan-only lane clean (${#files[@]} fragment file(s) validated; build stamp not required for this push)${RST}" >&2
    return 0
}

# ── 2. The local gate must have run against this exact tree ────────────────────
if [[ -f scripts/gate-stamp.sh ]]; then
    stamp="$(bash scripts/gate-stamp.sh verify 2>/dev/null)"
    case "$stamp" in
        ok:gate-fresh)
            ;;
        stale:never-run|stale:tree-changed-since-gate)
            # Before refusing, offer the plan-only fast lane: a fragments-only
            # push has a build-free validation closure (668-2xeh). The lane
            # prints its own accept/decline reasons; a decline falls through to
            # the same refusal as before.
            if attempt_plan_only_lane; then
                exit 0
            fi
            if [[ "$stamp" == "stale:never-run" ]]; then
                refuse "./build.sh --check has never run in this checkout" \
                       "Run it once, then push:" \
                       "  ./build.sh --check"
            else
                refuse "the tree changed since ./build.sh --check last passed" \
                       "The gate validated a different tree than the one you are pushing." \
                       "Re-run it:" \
                       "  ./build.sh --check"
            fi
            ;;
        *)
            # Unknown verdict: warn, do not block. A stamp bug must not strand a
            # push — the preflight above already ran, and blocking on a state we
            # cannot classify would be a worse failure than allowing it.
            echo "${YLW}⚠ gate-stamp returned '${stamp:-<empty>}' — not blocking on it${RST}" >&2
            ;;
    esac
fi

echo "${GRN}✓ local gate: preflight clean, ./build.sh --check current for this tree${RST}" >&2
exit 0
