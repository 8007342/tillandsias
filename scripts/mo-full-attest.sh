#!/usr/bin/env bash
# @trace order:614-2gqx, spec:meta-orchestration
#
# mo-full-attest.sh — full-mode terminal attestation for the
# meta-orchestration skill (order 614-2gqx).
#
# A full meta-orchestration cycle is green only when the in-forge agent emits
# a typed terminal marker AFTER the startup-boundary guard and the
# commit/push obligations pass, and when that marker's claimed remote head is
# actually reached. Without it, a normal provider exit between tool calls can
# discard local commits while every outer launcher returns zero — the
# 4a1410a2 breach (plan/issues/meta-orchestration-full-mode-exit-attestation-gap-2026-08-05.md).
#
# Marker grammar (the agent's FINAL output line in full mode):
#
#   MO-FULL: <DISPOSITION> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>
#
#   DISPOSITION ∈ {COMPLETE, BLOCKED}
#   LOCAL_SHA   = final local HEAD sha (40 lowercase hex)
#   BRANCH      = the working branch the cycle committed to
#   REMOTE_SHA  = the remote branch head after the push (40 lowercase hex)
#
# Valid invariants:
#   * LOCAL_SHA == REMOTE_SHA   — a marker may not follow an unpushed commit
#   * BRANCH matches the host's current branch (the forge is seeded from the
#     same checkout, so any mismatch means a wrong-target push)
#   * `git ls-remote origin refs/heads/<BRANCH>` converges to REMOTE_SHA
#     within a bounded window (the git-mirror relay is asynchronous).
#
# Usage:
#   scripts/mo-full-attest.sh check <log-file> [timeout-s]
#   scripts/mo-full-attest.sh fixture
#
# check — validate a real forge log (used by
#   scripts/litmus-opencode-e2e-launch.sh). The remote-head probe is
#   overridable with $MO_FULL_REMOTE_PROBE (a command whose stdout is the
#   current remote head) for hermetic fixtures; the default probe is
#   `git ls-remote origin refs/heads/<branch>`.
#
# fixture — run the hermetic failure scenarios (missing marker, malformed
#   marker, unpushed local commit, branch mismatch, remote-head mismatch)
#   plus a clean pass, against synthetic logs and a fake remote probe.
#   Never touches a live remote.
#
# Verdict: exactly one final line `MO-FULL: PASS` or
#   `MO-FULL: FAIL <one-line reason>`, diagnostic lines before it.
# Exit codes: 0 pass; 1 marker absent/malformed/inconsistent (unpushed
#   commit claim, branch mismatch); 2 valid marker whose remote head never
#   converged (unpushed in practice or relay lost).

set -uo pipefail

SHA_RE='^[0-9a-f]{40}$'

usage() {
    echo "MO-FULL: FAIL usage: $0 {check <log-file> [timeout-s]|fixture}" >&2
    exit 1
}

# remote_head <branch> — print the current remote head for <branch>.
# MO_FULL_REMOTE_PROBE overrides the probe for hermetic fixtures; default is
# the live git-mirror ref.
remote_head() {
    local branch="$1"
    if [ -n "${MO_FULL_REMOTE_PROBE:-}" ]; then
        bash -c "$MO_FULL_REMOTE_PROBE" 2>/dev/null || true
        return 0
    fi
    git ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk '{print $1; exit}'
}

# check_log <log-file> <timeout-s> — validate the marker in a real log.
# Prints diagnostic lines, then the final verdict line. Returns 0/1/2.
check_log() {
    local log="$1" timeout_s="$2"
    local marker disp local_sha branch remote_sha current_branch actual

    if [ ! -f "$log" ] || [ ! -s "$log" ]; then
        echo "MO-FULL: FAIL forge log missing or empty: $log"
        return 1
    fi

    marker="$(grep -E '^MO-FULL: ' "$log" 2>/dev/null | tail -1 || true)"
    if [ -z "$marker" ]; then
        echo "MO-FULL: FAIL missing MO-FULL terminal marker (provider likely exited between tool calls)"
        return 1
    fi

    # shellcheck disable=SC2034
    read -r _tag disp local_sha branch remote_sha <<< "$marker"
    case "$disp" in
        COMPLETE|BLOCKED) ;;
        *)
            echo "MO-FULL: FAIL malformed disposition '$disp' in: $marker"
            return 1
            ;;
    esac
    if ! printf '%s' "$local_sha" | grep -qE "$SHA_RE" \
        || ! printf '%s' "$remote_sha" | grep -qE "$SHA_RE"; then
        echo "MO-FULL: FAIL malformed sha in: $marker"
        return 1
    fi
    [ -n "$branch" ] || { echo "MO-FULL: FAIL missing branch in: $marker"; return 1; }

    if [ "$local_sha" != "$remote_sha" ]; then
        echo "MO-FULL: FAIL unpushed local commit: marker claims local=$local_sha remote=$remote_sha (local commit $local_sha was not pushed)"
        echo "MO-FULL:  found marker: $marker"
        return 1
    fi

    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$current_branch" != "$branch" ]; then
        echo "MO-FULL: FAIL branch mismatch: marker branch '$branch', host on '$current_branch'"
        echo "MO-FULL:  found marker: $marker"
        return 1
    fi

    local deadline now
    deadline=$(( $(date +%s) + timeout_s ))
    while :; do
        actual="$(remote_head "$branch" | tr -d '[:space:]')"
        if [ "$actual" = "$remote_sha" ]; then
            echo "MO-FULL: PASS $disp $branch $remote_sha"
            return 0
        fi
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || break
        sleep 5
    done
    echo "MO-FULL: FAIL remote head $remote_sha never reached (observed ${actual:-none} on $branch) after ${timeout_s}s — commit not durably pushed or relay lost"
    echo "MO-FULL:  found marker: $marker"
    return 2
}

# fixture — hermetic reproduction of the breach shapes. Each scenario builds a
# synthetic log plus a fake remote probe and asserts the validator verdict.
fixture() {
    local work branch
    work="$(mktemp -d "${TMPDIR:-/tmp}/mo-full-attest-fixture.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    local sha_a sha_b
    sha_a="$(printf 'a%.0s' {1..40})"
    sha_b="$(printf 'b%.0s' {1..40})"

    local -a failures=()
    local name logfile want expect_rc verdict actual_rc

    run_case() {
        # run_case <name> <log-file> <expect-exit> <verdict-substring> <probe>
        name="$1"; logfile="$2"; expect_rc="$3"; want="$4"; probe="$5"
        actual_rc=0
        MO_FULL_REMOTE_PROBE="$probe" "$0" check "$logfile" 2 >"$work/out" 2>&1 || actual_rc=$?
        verdict="$(grep -E '^MO-FULL: ' "$work/out" | tail -1 || true)"
        if [ "$actual_rc" -ne "$expect_rc" ]; then
            failures+=("$name: exit=$actual_rc expected=$expect_rc (verdict: $verdict)")
        elif [ "$expect_rc" -eq 0 ] && ! grep -Fq 'MO-FULL: PASS' "$work/out"; then
            failures+=("$name: expected MO-FULL: PASS, got '$verdict'")
        elif [ "$expect_rc" -ne 0 ] && ! grep -Fq "$want" "$work/out"; then
            failures+=("$name: expected '$want' in verdict, got: $(grep -E '^MO-FULL: ' "$work/out" | tail -1)")
        fi
    }

    # 1. early normal provider exit after a local commit, no marker at all.
    printf '%s\n' "some agent work line" "local commit made: 4a1410a2" > "$work/log-no-marker"
    run_case "no-marker" "$work/log-no-marker" 1 "missing MO-FULL terminal marker" "printf '${sha_a}'"

    # 2. malformed marker (short sha).
    printf '%s\n' "MO-FULL: COMPLETE deadbeef $branch deadbeef" > "$work/log-malformed"
    run_case "malformed-marker" "$work/log-malformed" 1 "malformed" "printf '${sha_a}'"

    # 3. marker after a local commit that was never pushed (local != remote).
    printf '%s\n' "MO-FULL: COMPLETE $sha_a $branch $sha_b" > "$work/log-unpushed"
    run_case "unpushed-commit" "$work/log-unpushed" 1 "unpushed local commit" "printf '${sha_b}'"

    # 4. marker on the wrong branch.
    printf '%s\n' "MO-FULL: COMPLETE $sha_a wrong-branch $sha_a" > "$work/log-branch"
    run_case "branch-mismatch" "$work/log-branch" 1 "branch mismatch" "printf '${sha_a}'"

    # 5. valid marker but the remote never reaches the claimed head (relay lost).
    printf '%s\n' "MO-FULL: COMPLETE $sha_a $branch $sha_a" > "$work/log-relay"
    run_case "remote-head-mismatch" "$work/log-relay" 2 "never reached" "printf '${sha_b}'"

    # 6. clean pass: valid marker, probe returns the claimed head.
    printf '%s\n' "MO-FULL: COMPLETE $sha_a $branch $sha_a" > "$work/log-pass"
    run_case "clean-pass" "$work/log-pass" 0 "" "printf '${sha_a}'"

    if [ "${#failures[@]}" -gt 0 ]; then
        printf 'FAIL: %s\n' "${failures[@]}" >&2
        echo "MO-FULL: FAIL fixture $((${#failures[@]})) scenario(s) did not match expected verdicts"
        return 1
    fi
    echo "PASS: mo-full-attest fixture 6/6 scenarios green (no-marker, malformed, unpushed-commit, branch-mismatch, remote-head-mismatch, clean-pass)"
    return 0
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
    check)
        [ $# -ge 1 ] || usage
        timeout_s="${2:-${LITMUS_GIT_DELTA_TIMEOUT_S:-120}}"
        check_log "$1" "$timeout_s"
        ;;
    fixture)
        fixture
        ;;
    *)
        usage
        ;;
esac
