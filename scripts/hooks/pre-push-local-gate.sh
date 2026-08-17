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
# ATTESTATION-LEDGER APPENDS (order 767-iukh): one carve-out to "new files
# only" — per-host ledgers under plan/mo-full-attestations.d/ grow by APPEND
# (mo-full-attest.sh record), so the Finalization bookkeeping commit arrives
# as a modification. It qualifies only when the pushed blob is a byte-exact
# append-only extension of the remote blob, every added line satisfies the
# attestation grammar with LOCAL_SHA == REMOTE_SHA, and
# check-mo-full-attestations.sh accepts the whole ledger. Anything else
# (rewrites, truncations, README.md, nested paths) falls to the full gate.
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

# ── 1b. Derived cheatsheet tree equals the authored tree ──────────────────────
# The tracked images/default/cheatsheets/ is embedded into the binary and is the
# ONLY cheatsheet source the end-user image build has, so a tracked copy that
# has fallen behind ships an INDEX advertising files the image does not contain
# — an expert citing what it cannot open. It is checked HERE, at push, because
# the divergence is most often introduced by an integration rather than an edit:
# a merge/rebase that brings a sibling's cheatsheet change desyncs the two trees
# with nobody having touched the derived copy (observed 2026-08-16, minutes
# after the check itself landed). ./build.sh --check does not run the
# cheatsheet-host-image-sync litmus, so without this the gate that guards every
# push could not see it.
# @trace spec:cheatsheet-tooling — methodology/cheatsheets.yaml storage_and_authority
if [[ -f scripts/stage-image-cheatsheets.sh ]]; then
    if ! cheat_out="$(bash scripts/stage-image-cheatsheets.sh --verify 2>&1)"; then
        refuse "derived cheatsheet tree is out of sync with cheatsheets/" \
               "$cheat_out" \
               "" \
               "Fix: scripts/stage-image-cheatsheets.sh --stage && git add -f images/default/cheatsheets"
    fi
fi

# ── Plan-only fast lane (order 668-2xeh) ───────────────────────────────────────
# Attempted only when the stamp is missing/stale. Emits one line per validated
# file — "plan-only lane: validated <path>" — so the push record names exactly
# what was accepted without a build. Returns 0 to accept the push (marker lines
# already printed), 1 to fall back to the full gate (reason already printed).
LANE_NOTES=()

attempt_plan_only_lane() {
    local -a files=() srcs=() bases=()
    local att_seen=0
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
            case "$path" in
                plan/mo-full-attestations.d/?*.md)
                    # Order 767-iukh: the Finalization bookkeeping commit
                    # (mo-full-attest.sh record) APPENDS to an existing
                    # per-host attestation ledger, so it arrives as status
                    # 'M' — the one modification with a build-free
                    # verifiable closure: append-only extension of the
                    # remote blob, marker grammar over the added lines, and
                    # check-mo-full-attestations.sh (all below). Before this
                    # branch, every full-mode cycle paid a full-gate re-run
                    # (~2.5 min measured) to push a 3-line bookkeeping
                    # commit whose content the dedicated checker already
                    # verifies.
                    if [[ "${path#plan/mo-full-attestations.d/}" == */* ]]; then
                        echo "plan-only lane: not applicable — '$path' is nested below plan/mo-full-attestations.d/ (full gate required)" >&2
                        return 1
                    fi
                    if [[ "$path" == "plan/mo-full-attestations.d/README.md" ]]; then
                        echo "plan-only lane: not applicable — '$path' is prose, not a per-host attestation ledger (full gate required)" >&2
                        return 1
                    fi
                    if [[ "$status" != "A" && "$status" != "M" ]]; then
                        echo "plan-only lane: not applicable — '$path' has status '$status' in the outgoing diff; only new or appended attestation ledgers qualify (full gate required)" >&2
                        return 1
                    fi
                    if [[ "$status" == "M" ]]; then
                        bases+=("$remote_sha")
                    else
                        bases+=("")
                    fi
                    att_seen=1
                    ;;
                plan/index.d/?*.yaml)
                    if [[ "$status" != "A" ]]; then
                        echo "plan-only lane: not applicable — '$path' has status '$status' in the outgoing diff; fragments are immutable, only NEW fragment files qualify (full gate required)" >&2
                        return 1
                    fi
                    if [[ "${path#plan/index.d/}" == */* ]]; then
                        echo "plan-only lane: not applicable — '$path' is nested below plan/index.d/ (full gate required)" >&2
                        return 1
                    fi
                    bases+=("")
                    ;;
                plan/loop_status.d/?*.md)
                    if [[ "$status" != "A" ]]; then
                        echo "plan-only lane: not applicable — '$path' has status '$status' in the outgoing diff; fragments are immutable, only NEW fragment files qualify (full gate required)" >&2
                        return 1
                    fi
                    if [[ "${path#plan/loop_status.d/}" == */* ]]; then
                        echo "plan-only lane: not applicable — '$path' is nested below plan/loop_status.d/ (full gate required)" >&2
                        return 1
                    fi
                    bases+=("")
                    ;;
                *)
                    echo "plan-only lane: not applicable — '$path' is outside plan/index.d/, plan/loop_status.d/, and plan/mo-full-attestations.d/ (full gate required)" >&2
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
    local have_yq=0 have_plan=0 plan_bin=""
    command -v yq >/dev/null 2>&1 && have_yq=1
    # Order 721-nyev: `-x` is a CLAIM; running the binary is evidence. On a
    # shared Windows/WSL checkout that test passes on a Linux ELF sitting
    # beside the runnable .exe, after which this lane reported on a validation
    # it never actually performed -- a gate vouching for evidence it did not
    # gather, which is the worst shape in this file.
    . "$(dirname "${BASH_SOURCE[0]}")/../plan-binary-probe.sh"
    plan_bin="$(resolve_plan_binary || true)"
    [[ -n "$plan_bin" ]] && have_plan=1
    if [[ $have_yq -eq 0 && $have_plan -eq 0 ]]; then
        echo "plan-only lane: not applicable — neither yq nor target/release/tillandsias-plan is available to validate fragments (fail closed; full gate required)" >&2
        return 1
    fi

    # Per-file validation runs against the PUSHED blob (git show <sha>:<path>),
    # not the worktree — the lane vouches for the bytes the remote receives.
    local tmp i blob added oldblob oldsz newsz _tag _disp _lsha _branch _rsha
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
            plan/mo-full-attestations.d/*)
                # Order 767-iukh: append-only + grammar closure. A modified
                # ledger must extend the remote blob byte-for-byte, and every
                # ADDED line must be blank, a '## <ISO-UTC> <host>' heading,
                # or a well-formed MO-FULL marker whose LOCAL_SHA equals
                # REMOTE_SHA (the record-time invariant). The dedicated
                # checker below re-validates the WHOLE ledger, including
                # own-host commit reachability.
                added="$tmp/added"
                if [[ -n "${bases[$i]}" ]]; then
                    oldblob="$tmp/oldblob"
                    if ! git show "${bases[$i]}:${files[$i]}" > "$oldblob" 2>/dev/null; then
                        echo "plan-only lane: validation FAILED — cannot read the remote base of ${files[$i]} (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                    oldsz="$(wc -c < "$oldblob")"
                    newsz="$(wc -c < "$blob")"
                    if [[ "$newsz" -le "$oldsz" ]] || ! head -c "$oldsz" "$blob" | cmp -s "$oldblob" -; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} is not an append-only extension of the remote ledger (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                    tail -c +"$((oldsz + 1))" "$blob" > "$added"
                else
                    cp "$blob" "$added"
                fi
                if LC_ALL=C grep -qvE '^(|## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z [A-Za-z0-9._-]+|MO-FULL: (COMPLETE|BLOCKED) [0-9a-f]{40} [A-Za-z0-9][A-Za-z0-9._/-]* [0-9a-f]{40})$' "$added"; then
                    echo "plan-only lane: validation FAILED — ${files[$i]} added lines break the attestation-ledger grammar (full gate required)" >&2
                    rm -rf "$tmp"; return 1
                fi
                if ! grep -qE '^MO-FULL: ' "$added"; then
                    echo "plan-only lane: validation FAILED — ${files[$i]} adds no MO-FULL marker line (full gate required)" >&2
                    rm -rf "$tmp"; return 1
                fi
                while read -r _tag _disp _lsha _branch _rsha; do
                    if [[ "$_lsha" != "$_rsha" ]]; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} added marker has LOCAL_SHA != REMOTE_SHA (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                done < <(grep -E '^MO-FULL: ' "$added")
                ;;
        esac
    done
    rm -rf "$tmp"

    # Fragment schema over the folded ledger, plus the fold-discard trap check.
    # Both need the tillandsias-plan binary; in-forge it exists. Absent, note
    # the skip honestly (yq already parsed every blob above).
    local out rc
    if [[ $have_plan -eq 1 ]]; then
        # A fragment `check` could not PARSE is skipped, and plain `check` still
        # exits ZERO on purpose (measured on windows 2026-08-15, order 753-*):
        # build.sh runs that command on every host, so a fleet-wide refusal
        # would make one host's typo every host's red build (699-dycj).
        #
        # This lane is different, and that is why it opts IN. Without yq it
        # DELEGATES its YAML parse to this command (see the LANE_NOTES above),
        # so a `packets: [unclosed` fragment sailed onto the trunk on the fast
        # lane while the lane printed "validated <path>" — this file's own
        # stated worst case, a gate vouching for evidence it did not gather.
        # --strict-fragments (796-4ydb) makes the skip the refusal the default
        # declines to make, and exit 3 distinguishes "corpus incomplete" from
        # exit 1's "ledger unsound" WITHOUT reading prose, which is what this
        # block used to do.
        # `&& rc=0 || rc=$?` rather than a bare assignment plus `rc=$?`: this
        # file is `set -uo pipefail` today, but a non-zero exit is now the
        # EXPECTED path here, and that shape stays correct if `-e` is ever added.
        out="$("$plan_bin" check --strict-fragments 2>&1)" && rc=0 || rc=$?
        if [[ $rc -eq 3 ]]; then
            echo "plan-only lane: validation FAILED — tillandsias-plan check could not PARSE a pushed fragment and skipped it (full gate required):" >&2
            printf '%s\n' "$out" | grep -E 'malformed:|does not parse and was SKIPPED' | head -6 | sed 's/^/  /' >&2
            return 1
        fi
        if [[ $rc -ne 0 ]]; then
            echo "plan-only lane: validation FAILED — tillandsias-plan check refused the folded ledger (full gate required):" >&2
            printf '%s\n' "$out" | head -6 | sed 's/^/  /' >&2
            return 1
        fi
        # LEGACY BACKSTOP, and it must stay until every host is past 796-4ydb.
        # A binary predating that order has no --strict-fragments; its `check`
        # arm ignores unknown trailing args entirely, so it exits 0 and the
        # typed refusal above never fires. Stale plan binaries on other hosts
        # are the normal case here (that is why order 569 exists), and silently
        # trading a working prose grep for a flag the local binary does not
        # implement would REMOVE this gate on exactly the hosts it was written
        # for. A current binary can never reach this line with a skipped
        # fragment, so this only ever catches an old one.
        if printf '%s' "$out" | grep -q 'does not parse and was SKIPPED'; then
            echo "plan-only lane: validation FAILED — tillandsias-plan check could not PARSE a pushed fragment and skipped it, and this binary predates --strict-fragments (full gate required):" >&2
            printf '%s' "$out" | grep 'does not parse and was SKIPPED' | head -6 | sed 's/^/  /' >&2
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

    # The AUTHOR-SIDE fragment parse gate (order 698-7n6q). It was wired into
    # build.sh and nowhere else -- and this lane exists precisely to accept a
    # push WITHOUT build.sh. So the one gate written to stop a malformed
    # fragment at its author was bypassed by the only path that skips the build,
    # which is the path fragments actually take. Measured windows 2026-08-15:
    # `packets: [unclosed` pushed clean through this lane.
    if [[ -f scripts/check-added-fragments-parse.sh ]]; then
        if ! out="$(bash scripts/check-added-fragments-parse.sh 2>&1)"; then
            echo "plan-only lane: validation FAILED — check-added-fragments-parse refused (full gate required):" >&2
            echo "$out" | head -6 | sed 's/^/  /' >&2
            return 1
        fi
    else
        LANE_NOTES+=("scripts/check-added-fragments-parse.sh absent — skipped")
    fi

    # Order 767-iukh: when the push touches the attestation ledger, the
    # dedicated gate must vouch for it — it re-validates the WHOLE ledger
    # (grammar on every file, commit reachability for this host's own file),
    # exactly as ./build.sh --check would have. Fail closed when it is
    # absent; fragment-only pushes are unaffected.
    if [[ $att_seen -eq 1 ]]; then
        if [[ -f scripts/check-mo-full-attestations.sh ]]; then
            if ! out="$(bash scripts/check-mo-full-attestations.sh 2>&1)"; then
                echo "plan-only lane: validation FAILED — check-mo-full-attestations refused (full gate required):" >&2
                echo "$out" | head -6 | sed 's/^/  /' >&2
                return 1
            fi
        else
            echo "plan-only lane: not applicable — scripts/check-mo-full-attestations.sh absent while the push touches plan/mo-full-attestations.d/ (fail closed; full gate required)" >&2
            return 1
        fi
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
    echo "plan-only lane: outgoing diff adds only new plan fragment files / append-only attestation-ledger records — accepting without the build stamp" >&2
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

# ── Stamp SCOPE enforcement (order 765-dt8h) ──────────────────────────────────
# A fresh stamp proves the gate ran against these bytes. It does NOT, on its
# own, prove the gate VALIDATED what is being pushed — `--check` and `--ci-full`
# validate materially different things, and once a scoped gate exists a stamp
# could cover a strict subset of the tree. So when the stamp declares a scope
# narrower than `full`, the outgoing diff's change classes must be a subset of
# it. Anything unclassifiable, unparseable, or unscopeable is STALE (fail
# closed) — the inverse of 634-39ik's fail-open polarity, which is correct only
# for a guard that ADDS enforcement. This one REMOVES coverage, so it refuses.
#
# `full` short-circuits before any diff work, so the overwhelmingly common path
# costs one extra subshell and nothing else.
enforce_stamp_scope() {
    local scope
    scope="$(bash scripts/gate-stamp.sh scope 2>/dev/null)"
    case "$scope" in
        full)
            return 0
            ;;
        stale:*|"")
            refuse "the gate stamp does not declare a usable scope (${scope:-<no verdict>})" \
                   "A stamp whose scope cannot be read cannot be trusted to cover this push." \
                   "Re-run the full gate:" \
                   "  ./build.sh --check"
            ;;
    esac

    # Scoped stamp: the outgoing diff must not reach outside it.
    if [[ -z "$REFS" ]]; then
        refuse "the gate stamp is scoped to '$scope' but there is no ref list to scope the outgoing diff against" \
               "A scoped stamp can only be honoured when the push can be classified." \
               "Re-run the full gate:" \
               "  ./build.sh --check"
    fi

    local -a paths=()
    local local_ref local_sha remote_ref remote_sha path
    while read -r local_ref local_sha remote_ref remote_sha; do
        [[ -n "$local_ref" ]] || continue
        if [[ "$local_sha" =~ ^0+$ ]]; then continue; fi
        if [[ "$remote_sha" =~ ^0+$ ]] || ! git cat-file -e "$remote_sha" 2>/dev/null; then
            refuse "the gate stamp is scoped to '$scope' but $remote_ref has no usable local base to diff against" \
                   "A scoped stamp can only be honoured when the push can be classified." \
                   "Re-run the full gate:" \
                   "  ./build.sh --check"
        fi
        while IFS= read -r path; do
            [[ -n "$path" ]] && paths+=("$path")
        done < <(git diff --name-only --no-renames "$remote_sha" "$local_sha" -- 2>/dev/null)
    done <<< "$REFS"

    if [[ ${#paths[@]} -eq 0 ]]; then
        return 0
    fi

    local -a diff_classes=()
    local cls covered
    while IFS= read -r cls; do
        [[ -n "$cls" ]] && diff_classes+=("$cls")
    done < <(printf '%s\n' "${paths[@]}" | bash scripts/gate-stamp.sh classify 2>/dev/null)

    if [[ ${#diff_classes[@]} -eq 0 ]]; then
        refuse "the outgoing diff could not be classified against the scoped stamp ('$scope')" \
               "Re-run the full gate:" \
               "  ./build.sh --check"
    fi

    local -a missing=()
    for cls in "${diff_classes[@]}"; do
        covered=0
        case ",$scope," in
            *",$cls,"*) covered=1 ;;
        esac
        [[ $covered -eq 1 ]] || missing+=("$cls")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local missing_csv
        missing_csv="$(printf '%s,' "${missing[@]}")"; missing_csv="${missing_csv%,}"
        refuse "the gate stamp is scoped to '$scope' but this push also changes: $missing_csv" \
               "The gate that stamped this tree never validated those change classes." \
               "Re-run the full gate:" \
               "  ./build.sh --check"
    fi

    echo "${GRN}✓ local gate: scoped stamp '$scope' covers every outgoing change class${RST}" >&2
    return 0
}

# ── 2. The local gate must have run against this exact tree ────────────────────
if [[ -f scripts/gate-stamp.sh ]]; then
    stamp="$(bash scripts/gate-stamp.sh verify 2>/dev/null)"
    case "$stamp" in
        ok:gate-fresh)
            enforce_stamp_scope
            ;;
        stale:legacy-stamp-format)
            # Order 765-dt8h migration. The stamp predates scope recording, so
            # what it validated is unknowable from the file. The plan-only lane
            # still applies (it never consults the stamp's scope), and anything
            # else re-runs the gate once.
            if attempt_plan_only_lane; then
                exit 0
            fi
            refuse "the gate stamp predates scope recording (order 765-dt8h)" \
                   "Stamps now record WHICH change classes the gate validated, and this one" \
                   "cannot say. Re-run the gate once to write a scoped stamp:" \
                   "  ./build.sh --check"
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
