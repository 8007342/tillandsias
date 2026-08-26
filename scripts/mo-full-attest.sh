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
#   scripts/mo-full-attest.sh self [timeout-s]
#   scripts/mo-full-attest.sh record [ledger-file] [timeout-s]
#   scripts/mo-full-attest.sh host
#   scripts/mo-full-attest.sh fixture
#
# check — validate a real forge log (used by
#   scripts/litmus-opencode-e2e-launch.sh). The remote-head probe is
#   overridable with $MO_FULL_REMOTE_PROBE (a command whose stdout is the
#   current remote head) for hermetic fixtures; the default probe is
#   `git ls-remote origin refs/heads/<branch>`.
#
# self — DERIVE-and-verify the marker against the LIVE repo, run by a full-mode
#   cycle on ITSELF right before it emits (so EVERY lane self-checks, not only
#   the litmus launcher that calls `check`). Reads HEAD, the current branch, and
#   the converged remote head directly — never a typed value — and FAILS LOUD
#   (typed `MO-FULL: FAIL`, non-zero exit) if local HEAD is not durably on the
#   remote, the branch is main/detached, or `git ls-remote` does not converge
#   within the same bounded window as check. On success it prints ONLY the
#   derived, verified marker line to stdout, which the cycle emits verbatim, so
#   a hand-typed or fabricated SHA is structurally impossible. Disposition
#   defaults to COMPLETE; set MO_FULL_DISPOSITION=BLOCKED for a
#   blocked-but-pushed cycle. Same $MO_FULL_REMOTE_PROBE override as check.
#
# record — make the verified marker DURABLE (651-2x5s): run the self
#   verification, and on success append the verified line to the per-host
#   ledger under plan/mo-full-attestations.d/<host>.md (or the file given as
#   the first argument), then print the marker. The ledger is a committed,
#   machine-parseable log automation can consume — a marker recorded there is
#   evidence a transcript marker is not. The ledger line attests the WORK head
#   at record time; the cycle then commits+pushes the ledger and re-derives the
#   TERMINAL marker at the head containing the record (see
#   methodology/mo-full-attestation.yaml bookkeeping_commit). Never touches the
#   ledger on failure — a failed verification must not leave a record behind.
#
# host — print the host label that names this host's ledger file
#   (MO_FULL_HOST if set, else `forge` inside the forge container, else the
#   short hostname lowercased). Shared by record and
#   check-mo-full-attestations.sh so the two can never drift apart.
#
# fixture — run the hermetic failure scenarios (missing marker, malformed
#   marker, unpushed local commit, branch mismatch, remote-head mismatch, and a
#   well-formed-but-fabricated SHA that matches nothing on the remote — the
#   2026-08-10 breach shape) plus a clean pass, against synthetic logs and a
#   fake remote probe. Never touches a live remote.
#
# Verdict: exactly one final line `MO-FULL: PASS` or
#   `MO-FULL: FAIL <one-line reason>`, diagnostic lines before it.
# Exit codes: 0 pass; 1 marker absent/malformed/inconsistent (unpushed
#   commit claim, branch mismatch); 2 valid marker whose remote head never
#   converged (unpushed in practice or relay lost).

set -uo pipefail

# Order 756-hn3a: the node-name fallback chain that used to live inline in
# mo_full_host() is now the SHARED probe tillandsias_node_name() in
# scripts/agent-identity.sh, so the canonical agent-identity helper and this
# ledger label derive from ONE implementation (743-mgf3) and cannot drift.
# The source path is computed with parameter expansion, not dirname(1), so
# `host` mode keeps resolving with an empty PATH — builtins only, same
# posture as the probe itself.
_ai_dir="${BASH_SOURCE[0]%/*}"
[ "$_ai_dir" = "${BASH_SOURCE[0]}" ] && _ai_dir=.
# shellcheck source=scripts/agent-identity.sh
. "$_ai_dir/agent-identity.sh"

SHA_RE='^[0-9a-f]{40}$'

usage() {
    echo "MO-FULL: FAIL usage: $0 {check <log-file> [timeout-s]|self [timeout-s]|record [ledger-file] [timeout-s]|host|fixture}" >&2
    exit 1
}

# mo_full_host — the stable host label that names this host's ledger file.
# The forge container reports a generated container hostname; the mesh
# convention (plan/loop_status.d headings) calls it `forge`. On real hosts the
# short hostname (lowercased) is stable. MO_FULL_HOST overrides for tests and
# unusual deployments. This is the single source of truth for the label —
# check-mo-full-attestations.sh derives the current host's ledger by calling
# `mo-full-attest.sh host`, so the two can never disagree.
mo_full_host() {
    if [ -n "${MO_FULL_HOST:-}" ]; then
        printf '%s' "$MO_FULL_HOST"
        return 0
    fi
    if [ -f "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.forge-startup-context.md" ]; then
        printf '%s' 'forge'
        return 0
    fi
    # Node-name fallback chain: the SHARED probe (order 756-hn3a), sourced
    # from scripts/agent-identity.sh above. The chain and its builtin-only
    # post-processing are unchanged from when it lived inline here:
    # hostname -s -> hostname -> uname -n -> /etc/hostname, then strip the
    # domain and lowercase with bash builtins (743-mgf3, incl. the MSYS
    # `hostname -s` rejection measured 2026-08-15).
    printf '%s' "$(tillandsias_node_name)"
    return 0
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

# converge_remote <branch> <want-sha> <timeout-s> — poll the remote head for
# <branch> until it equals <want-sha> or the bounded window closes. Prints the
# last observed head to stdout; returns 0 on convergence, 1 otherwise. Shared by
# check (verifying a marker's claimed remote) and self (verifying live HEAD), so
# the polling grammar lives in one place.
converge_remote() {
    local branch="$1" want="$2" timeout_s="$3"
    local deadline now actual
    deadline=$(( $(date +%s) + timeout_s ))
    while :; do
        actual="$(remote_head "$branch" | tr -d '[:space:]')"
        if [ "$actual" = "$want" ]; then
            printf '%s' "$actual"
            return 0
        fi
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || break
        sleep 5
    done
    printf '%s' "$actual"
    return 1
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
        # A MISSING MARKER HAS AT LEAST TWO CAUSES AND THIS NAMED ONLY ONE.
        #
        # Measured on macuahuitl 2026-08-18, order 817-8czp. The e2e's forge
        # lane failed here and this line said "provider likely exited between
        # tool calls". The provider did not exit. The in-forge cycle ran
        # correctly, hit the Credential Channel Guard, got
        # `blocked:upstream-auth-stale` (the mirror's write-authorization
        # verdict was 21504s old against a 900s ceiling), and REFUSED to do
        # committable work — exactly as the exit contract requires. A blocked
        # cycle that cannot push MUST NOT emit a marker; its absence is the
        # designed loud failure. So the one state where the missing marker is
        # CORRECT was reported as the one state where the agent died, and the
        # reader is sent looking for a crash instead of at the credential.
        #
        # Same shape as 797-5kqe and the stale-healthy corpse of 798-tk7b: the
        # status is not merely absent, it asserts the opposite. The lane still
        # FAILS — it did not complete — but it now fails with the cause the log
        # actually carries.
        _mo_refusal="$(grep -oE 'blocked:[a-z0-9][a-z0-9-]*' "$log" 2>/dev/null | tail -1 || true)"
        if [ -n "$_mo_refusal" ]; then
            echo "MO-FULL: FAIL no marker because the cycle REFUSED and stopped: ${_mo_refusal} — a blocked cycle that cannot push emits no marker BY DESIGN, so the fault is whatever produced ${_mo_refusal}, not the agent"
            return 1
        fi
        echo "MO-FULL: FAIL missing MO-FULL terminal marker and NO refusal verdict in the log — cause unproven; the provider may have exited between tool calls"
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

    if actual="$(converge_remote "$branch" "$remote_sha" "$timeout_s")"; then
        echo "MO-FULL: PASS $disp $branch $remote_sha"
        return 0
    fi
    echo "MO-FULL: FAIL remote head $remote_sha never reached (observed ${actual:-none} on $branch) after ${timeout_s}s — commit not durably pushed or relay lost"
    echo "MO-FULL:  found marker: $marker"
    return 2
}

# self_attest <timeout-s> — DERIVE-and-verify the marker against the LIVE repo,
# run by a full-mode cycle on ITSELF right before it emits. Reads HEAD and the
# current branch directly and requires the remote to converge on that HEAD, so a
# hand-typed or fabricated SHA is impossible: the value printed is the value
# verified. Fails loud (typed MO-FULL: FAIL, non-zero) on a detached or main
# branch, an unreadable HEAD, or a remote that never converges within the
# window. On success prints ONLY the derived, verified marker to stdout.
self_attest() {
    local timeout_s="$1"
    local disp local_sha branch actual

    disp="${MO_FULL_DISPOSITION:-COMPLETE}"
    case "$disp" in
        COMPLETE|BLOCKED) ;;
        *)
            echo "MO-FULL: FAIL invalid MO_FULL_DISPOSITION '$disp' (want COMPLETE or BLOCKED)"
            return 1
            ;;
    esac

    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        echo "MO-FULL: FAIL detached HEAD — a marker must name the branch the cycle pushed to"
        return 1
    fi
    if [ "$branch" = "main" ]; then
        echo "MO-FULL: FAIL refusing to attest on protected branch 'main' — full-mode cycles commit to a platform branch"
        return 1
    fi

    local_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if ! printf '%s' "$local_sha" | grep -qE "$SHA_RE"; then
        echo "MO-FULL: FAIL cannot read a valid local HEAD sha (not a git repo, or an unborn branch)"
        return 1
    fi

    # A verified startup boundary is a PRECONDITION of the marker (order
    # 717-3bvv, extending 614-2gqx). Decision recorded in
    # plan/issues/enhancement-worktree-boundary-snapshot-is-unenforced-2026-08-13.md:
    # candidate shape 1 was adopted. The marker already attests that HEAD is
    # durably on the remote; it now also attests that the cycle recorded a
    # startup boundary and verified the worktree against it. Without this the
    # guard was a convention — cycle 16 on windows skipped the snapshot, and a
    # valid marker printed anyway.
    #
    # It fails in the loud direction: no marker, which every outer launcher
    # already treats as failure. A cycle that skipped the snapshot has not met
    # its exit contract, and that is the fact being reported.
    local stamp verified_head
    stamp="${MO_FULL_BOUNDARY_STAMP:-$(git rev-parse --git-dir 2>/dev/null)/boundary-verified}"
    verified_head="$(cat "$stamp" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$verified_head" ]; then
        echo "MO-FULL: FAIL no verified startup boundary for this cycle — run the guard's snapshot at Start Of Cycle and verify at Finalization; do NOT emit a marker"
        return 1
    fi
    if [ "$verified_head" != "$local_sha" ]; then
        echo "MO-FULL: FAIL startup boundary was verified at $verified_head but HEAD is now $local_sha — re-run the guard's verify after the cycle's last commit; do NOT emit a marker"
        return 1
    fi

    if actual="$(converge_remote "$branch" "$local_sha" "$timeout_s")"; then
        printf 'MO-FULL: %s %s %s %s\n' "$disp" "$local_sha" "$branch" "$local_sha"
        return 0
    fi
    echo "MO-FULL: FAIL local HEAD $local_sha is not durably on origin/$branch (observed ${actual:-none}) after ${timeout_s}s — commit unpushed or relay lost; do NOT emit a marker"
    return 2
}

# record_attest <ledger-file> <timeout-s> — DERIVE-and-verify the marker via
# self, and on success append it to the durable ledger. The ledger entry is:
#
#   ## <ISO-UTC-timestamp> <host>
#   MO-FULL: <DISPOSITION> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>
#
# On success prints ONLY the recorded marker (so the caller can emit it); on
# failure prints self's typed FAIL through stderr, exits non-zero, and MUST NOT
# create or modify the ledger — a failed verification leaves no record.
record_attest() {
    local ledger="$1" timeout_s="$2"
    local out marker disp local_sha branch remote_sha ts host

    if [ -z "$ledger" ]; then
        echo "MO-FULL: FAIL record: missing ledger file path"
        return 1
    fi
    if [ -z "$(mo_full_host | tr -d '[:space:]')" ]; then
        echo "MO-FULL: FAIL record: cannot determine host label (no MO_FULL_HOST, no /etc/hostname hostname command)"
        return 1
    fi

    out="$(mktemp "${TMPDIR:-/tmp}/mo-full-record.XXXXXX")"
    "$0" self "$timeout_s" >"$out" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$out" >&2
        rm -f "$out"
        return "$rc"
    fi
    marker="$(grep -E '^MO-FULL: ' "$out" | tail -1 || true)"
    rm -f "$out"
    if [ -z "$marker" ]; then
        echo "MO-FULL: FAIL record: self-attestation produced no marker line"
        return 1
    fi
    # shellcheck disable=SC2034
    read -r _tag disp local_sha branch remote_sha <<< "$marker"
    if [ "$local_sha" != "$remote_sha" ] || ! printf '%s' "$local_sha" | grep -qE "$SHA_RE"; then
        echo "MO-FULL: FAIL record: internal error — self returned an unverifiable marker: $marker"
        return 1
    fi

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(mo_full_host)"

    mkdir -p "$(dirname "$ledger")"
    if [ ! -f "$ledger" ]; then
        printf '%s\n' "# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)" \
            "# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record" \
            "# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)" \
            "# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx)." \
            "# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check)." >>"$ledger"
    fi
    printf '\n## %s %s\n%s\n' "$ts" "$host" "$marker" >>"$ledger"

    # The cycle is now attested; tell the checkout lock so the host's NEXT fire
    # is not refused by this cycle's own leftover lock (order 899-q9di).
    #
    # This is here, and not left to the agent, because Finalization step 9 says
    # the marker is the FINAL OUTPUT LINE and step 9b asks for a release after
    # it — two rules that cannot both be obeyed, so the release must not depend
    # on which one the agent believed. `record` is the right hook precisely
    # because it runs ONCE per cycle; `self` may be called repeatedly mid-cycle.
    #
    # Best-effort in every direction: stdout stays the marker alone (callers
    # emit it verbatim), and a failure here never changes the exit code — an
    # unmarked lock just falls back to the pre-existing stale bound, which is
    # the behaviour that existed before this line.
    local _lockjs
    _lockjs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cycle-checkout-lock.sh"
    if [ -x "$_lockjs" ]; then
        "$_lockjs" mark-attested >/dev/null 2>&1 || true
    fi

    printf '%s\n' "$marker"
    return 0
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

    # 1b. ORDER 817-8czp. The SAME missing marker, but the log carries an
    # explicit refusal. This must NOT be reported as a provider crash: a
    # blocked cycle that cannot push emits no marker by design. Still exit 1 —
    # the lane did not complete — but with the cause the log actually carries.
    # The pair is the control: 1 and 1b differ ONLY in the refusal line, so a
    # regression that collapses them turns exactly one of the two red.
    printf '%s\n' \
        "Cycle preflight: ok." \
        "Credential channel guard: blocked:upstream-auth-stale. This blocks the cycle." \
        "BLOCKED — no committable work performed." > "$work/log-refused"
    run_case "no-marker-but-refused" "$work/log-refused" 1 "REFUSED and stopped: blocked:upstream-auth-stale" "printf '${sha_a}'"

    # 1c. The refusal branch must not fire on prose that merely contains the
    # word: only a `blocked:<verdict>` token counts. Without this, any log
    # mentioning "blocked" would stop naming a real provider death.
    printf '%s\n' "the lane was blocked for a while then the provider vanished" > "$work/log-prose-blocked"
    run_case "no-marker-prose-only" "$work/log-prose-blocked" 1 "NO refusal verdict in the log" "printf '${sha_a}'"

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

    # 7. NEGATIVE CONTROL (651-2x5s): a well-formed but FABRICATED SHA — valid
    #    40-hex, local==remote in the marker, correct branch, so it satisfies
    #    EVERY glance-check — that does not match the remote. This is the exact
    #    2026-08-10 breach shape: the first 8 chars were copied from `git push`
    #    output, the remaining 32 invented to look like a SHA. It must be
    #    REJECTED by ls-remote non-convergence, never accepted as a proof.
    local sha_real sha_fab
    sha_real="2a8b69677e19131183b9dc24b1d76e4d90cd872e"   # the true head
    sha_fab="2a8b6967b0d3d0e7b8a1e0a1b8f0e5c4d3a2b1c0"    # 8 real + 32 invented
    printf '%s\n' "MO-FULL: COMPLETE $sha_fab $branch $sha_fab" > "$work/log-fabricated"
    run_case "fabricated-sha" "$work/log-fabricated" 2 "never reached" "printf '${sha_real}'"

    # 8-10. self-mode boundary precondition (order 717-3bvv). `self` derives
    #    from the LIVE repo, so these need the real branch to be attestable;
    #    on a `main` checkout self refuses for a different, correct reason and
    #    the scenarios would prove nothing.
    local self_cases=0 live_branch live_head
    live_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    live_head="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$live_head" ] && [ -n "$live_branch" ] && [ "$live_branch" != "main" ] && [ "$live_branch" != "HEAD" ]; then
        self_cases=3
        run_self_case() {
            # run_self_case <name> <stamp-file> <expect-exit> <verdict-substring>
            local sname="$1" sstamp="$2" src_want="$3" swant="$4" src=0
            MO_FULL_BOUNDARY_STAMP="$sstamp" \
            MO_FULL_REMOTE_PROBE="printf '${live_head}'" \
                "$0" self 2 >"$work/self-out" 2>&1 || src=$?
            if [ "$src" -ne "$src_want" ]; then
                failures+=("$sname: exit=$src expected=$src_want (out: $(tail -1 "$work/self-out"))")
            elif ! grep -Fq "$swant" "$work/self-out"; then
                failures+=("$sname: expected '$swant', got: $(tail -1 "$work/self-out")")
            fi
        }

        # 8. the cycle-16 shape: everything committed and pushed, but no
        #    boundary was ever recorded. Must refuse to print a marker.
        run_self_case "self-no-boundary" "$work/absent-stamp" 1 \
            "no verified startup boundary"

        # 9. a boundary verified BEFORE the cycle's last commit — the stamp
        #    exists, so a mere existence test would pass it, and the worktree it
        #    attests is not the one being pushed.
        printf '%s\n' "$sha_a" >"$work/stale-stamp"
        run_self_case "self-stale-boundary" "$work/stale-stamp" 1 \
            "startup boundary was verified at"

        # 10. NEGATIVE CONTROL: a cycle that DID snapshot and verify at the head
        #     it is attesting still gets its marker. Without this, the new
        #     precondition could degrade into refusing every cycle and read as
        #     "working".
        printf '%s\n' "$live_head" >"$work/good-stamp"
        run_self_case "self-verified-boundary" "$work/good-stamp" 0 \
            "MO-FULL: COMPLETE $live_head $live_branch $live_head"

        # 11-12. record mode — the durable-ledger path (651-2x5s). record runs
        #    self internally, so these use the same live-repo gating and must
        #    never touch the real ledger (always a scratch file under $work).
        local ledger_path
        ledger_path="$work/ledger.md"
        run_record_case() {
            # run_record_case <name> <stamp-file> <expect-exit>
            local rname="$1" rstamp="$2" rrc_want="$3" rrc=0
            rm -f "$ledger_path"
            MO_FULL_BOUNDARY_STAMP="$rstamp" \
            MO_FULL_REMOTE_PROBE="printf '${live_head}'" \
                "$0" record "$ledger_path" 2 >"$work/record-out" 2>&1 || rrc=$?
            if [ "$rrc" -ne "$rrc_want" ]; then
                failures+=("$rname: exit=$rrc expected=$rrc_want (out: $(tail -1 "$work/record-out"))")
            elif [ "$rrc_want" -eq 0 ]; then
                if ! grep -Fq "MO-FULL: COMPLETE $live_head $live_branch $live_head" "$work/record-out"; then
                    failures+=("$rname: expected verified marker on stdout, got: $(tail -1 "$work/record-out")")
                elif ! grep -Fq "MO-FULL: COMPLETE $live_head $live_branch $live_head" "$ledger_path"; then
                    failures+=("$rname: expected marker appended to ledger, ledger: $(cat "$ledger_path")")
                elif [ "$(grep -c '^MO-FULL: ' "$ledger_path")" -ne 1 ]; then
                    failures+=("$rname: expected exactly one marker line in ledger")
                fi
            elif [ -e "$ledger_path" ]; then
                failures+=("$rname: failed verification must NOT create or touch the ledger")
            fi
        }

        # 11. record appends the verified marker to the ledger and prints it.
        run_record_case "record-verified-boundary" "$work/good-stamp" 0 ""

        # 12. NEGATIVE CONTROL: record with no boundary must fail AND leave the
        #     ledger untouched — a failed verification records nothing.
        run_record_case "record-no-boundary" "$work/absent-stamp" 1 "no verified startup boundary"
    fi

    if [ "${#failures[@]}" -gt 0 ]; then
        printf 'FAIL: %s\n' "${failures[@]}" >&2
        echo "MO-FULL: FAIL fixture $((${#failures[@]})) scenario(s) did not match expected verdicts"
        return 1
    fi
    if [ "$self_cases" -eq 0 ]; then
        # Say what was NOT run. A fixture that silently covers less on some
        # checkouts reports the same "green" as one that covered everything.
        echo "PASS: mo-full-attest fixture 9/9 check scenarios green (no-marker, no-marker-but-refused, no-marker-prose-only, malformed, unpushed-commit, branch-mismatch, remote-head-mismatch, clean-pass, fabricated-sha); self/record boundary scenarios SKIPPED — not attestable from branch '${live_branch:-none}'"
        return 0
    fi
    echo "PASS: mo-full-attest fixture 14/14 scenarios green (no-marker, no-marker-but-refused, no-marker-prose-only, malformed, unpushed-commit, branch-mismatch, remote-head-mismatch, clean-pass, fabricated-sha, self-no-boundary, self-stale-boundary, self-verified-boundary, record-verified-boundary, record-no-boundary)"
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
    self)
        timeout_s="${1:-${LITMUS_GIT_DELTA_TIMEOUT_S:-120}}"
        self_attest "$timeout_s"
        ;;
    record)
        ledger="${1:-plan/mo-full-attestations.d/$(mo_full_host).md}"
        timeout_s="${2:-${LITMUS_GIT_DELTA_TIMEOUT_S:-120}}"
        record_attest "$ledger" "$timeout_s"
        ;;
    host)
        mo_full_host
        ;;
    fixture)
        fixture
        ;;
    *)
        usage
        ;;
esac
