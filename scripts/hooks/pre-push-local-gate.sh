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


# ── ORDER 877-mynm: AN EMPTY REF LIST MEANS GIT IS PUSHING NOTHING ──────────
#
# This guard used to fall through to the full gate whenever stdin carried no
# refs, printing "plan-only lane: not applicable — no ref list on stdin" and
# then, on a stale stamp, refusing with "the tree changed since ./build.sh
# --check last passed". Both lines are true and the conclusion was wrong,
# because nobody had decoded what an empty list MEANS.
#
# MEASURED, hermetically, against a scratch repo with a bare remote (the
# fixture is scripts/test-pre-push-empty-ref-list.sh):
#
#   fast-forward push .................... 125 bytes, one ref
#   git push --dry-run origin HEAD ....... 108 bytes, one ref
#   already up to date ................... 0 bytes
#   non-fast-forward, remote-tracking ref
#     CURRENT (git already knows) ........ 0 bytes
#   non-fast-forward, remote-tracking ref
#     STALE (git does not know yet) ...... 125 bytes, then the REMOTE rejects
#
# The list is empty exactly when git has already decided to send nothing. Git
# still runs the hook — it always does — but there is no ref to gate. So the
# expensive path was being paid for a push that cannot happen, and the reader
# was sent to `./build.sh --check` when the actual remedy was `git pull
# --rebase`. Measured on pirria at ~90s per wasted gate, recurring by
# construction: the claim-before-work discipline races other hosts, and losing
# that race is precisely how the remote-tracking ref ends up current-and-ahead.
#
# THIS IS NOT A LICENCE TO ACCEPT AN UNSCOPED PUSH (877-mynm criterion 3).
# "No refs" and "refs I could not scope" are different facts. When a ref IS
# outgoing and its range cannot be determined, every refusal below stands
# exactly as written; the plan-only lane still falls back to the full gate, and
# the full gate still refuses a stale stamp. What changes is only the case where
# there is nothing to gate at all.
if [[ -z "${REFS//[[:space:]]/}" ]]; then
    echo "${GRN}✓ local gate: no refs on stdin — git is pushing nothing (already up to date, or a non-fast-forward it has already declined). Nothing to gate; if you expected a push, fetch and rebase.${RST}" >&2
    exit 0
fi
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

# ── 0. Salvage refs are exempt, by definition (872-c9nd) ──────────────────────
# A `salvage/<host>/<yyyymmdd>-<slug>` ref is a COPY of a dirty worktree pushed
# so the work cannot be lost — it is expected to be half-edited, unbuildable,
# and to carry a tree no gate has ever seen. Requiring a green build stamp of it
# makes the mechanism unusable, which is exactly what happened: the ref grammar
# has been accepted by the pre-receive gate (and deliberately exempted from its
# YAML check) since before 872-c9nd, and nothing ever pushed one. Four hours of
# finished work were then deleted with a fresh clone.
#
# Exempt ONLY when every ref in this push is a salvage ref, so a salvage cannot
# be used to smuggle a normal branch past the gate. Nothing here can reach
# main/linux-next: the grammar has its own namespace and the pre-receive gate
# enforces it independently.
#
# THIS BLOCK MUST BE THE HOOK'S FIRST DECISION, and originally it was not.
# Placed after release-preflight and the cheatsheet-sync guard, a salvage from
# a dirty tree whose dirt included a cheatsheet edit was REFUSED by the sync
# guard before this exemption was ever consulted — measured live on macuahuitl
# 2026-08-24 (`fail:salvage:push:` with the sync guard's refusal behind it).
# yoga's destroyed dirt contained cheatsheets/concurrent-git/
# crdt-ledger-fragments.md, so the net would have failed the exact incident it
# was built for. Any guard that inspects WORKTREE STATE will, on some dirty
# tree, refuse the push that exists to preserve that dirty tree — so no such
# guard may run before this line. Origin held ZERO salvage refs when the
# 2026-08-24 retrospective checked; that is what "unusable safety net" looks
# like from the outside: nothing fails, nothing is saved.
_all_salvage=1
_any_ref=0
_salvage_delete=""
while read -r _l _ls _remote_ref _rs; do
    [[ -z "${_remote_ref:-}" ]] && continue
    _any_ref=1
    case "$_remote_ref" in
        refs/heads/salvage/*)
            # DELETION PROTECTION (874-w2gc). The exemption used to wave
            # deletions through with the same enthusiasm as rescues: during
            # 874-s8vf's bring-up a salvage ref was deleted with one command
            # and nothing so much as asked. A salvage ref is by definition the
            # ONLY copy of work that existed nowhere else — fine to reap for a
            # test artifact, terrifying for a real rescue, and the hook cannot
            # tell them apart. So deletion requires the explicit override; the
            # decision and its reasoning are recorded on 874-w2gc's ledger row.
            if [[ "$_ls" =~ ^0+$ ]]; then
                _salvage_delete="$_remote_ref"
            fi
            ;;
        *) _all_salvage=0 ;;
    esac
done < <(printf '%s\n' "$REFS")
if [[ "$_any_ref" -eq 1 && "$_all_salvage" -eq 1 ]]; then
    if [[ -n "$_salvage_delete" && "${TILLANDSIAS_SALVAGE_DELETE_OK:-0}" != "1" ]]; then
        refuse "deleting salvage ref $_salvage_delete — a salvage ref may be the ONLY copy of rescued work (874-w2gc)" \
               "Confirm the rescued content is merged or consciously abandoned (check the" \
               "ledger event scripts/sweep-salvage-refs.sh filed for it), then re-run with:" \
               "  TILLANDSIAS_SALVAGE_DELETE_OK=1 git push ..." \
               "Mixed pushes: delete salvage refs in their own push, separate from rescues."
    fi
    echo "${GRN}✓ local gate: salvage ref — exempt by design (872-c9nd); a dirty-tree copy is not expected to build${RST}" >&2
    exit 0
fi

# ── 1. Release preflight ───────────────────────────────────────────────────────
if [[ -f scripts/release-preflight.sh ]]; then
    verdict="$(bash scripts/release-preflight.sh 2>/dev/null | tail -1)"
    rc=$?
    if [[ $rc -ne 0 || "$verdict" != "ok:release-preflight" ]]; then
        # head -12, not -6 (order 800-vk2p): the preflight's own header plus a
        # branch-aware remedy runs longer than six lines, and this hook is where
        # a stuck pusher actually reads the refusal. A cap that truncates the
        # remedy hides the one line that unblocks them.
        detail="$(bash scripts/release-preflight.sh 2>&1 >/dev/null | head -12)"
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

# ORDER 1056-5344. The paths THIS PUSH ITSELF changes, excluding what a
# mandated merge of trunk dragged in.
#
# THE COMPOSITION THAT BROKE THE LANE. methodology pull_merge_cadence.pre_push_gate
# requires merging origin/linux-next into a platform branch before EVERY push.
# That merge brings other hosts' non-plan files into the diff against the
# PLATFORM remote — they are new relative to windows-next even though they are
# old on trunk — and the lane judged that whole diff. So the two rules compose
# into "plan-only only if trunk has not moved", and the busier trunk is the less
# reachable the lane. esmeraldinha hit it 2026-09-05 with a one-fragment cycle
# on a night the fleet landed several times an hour.
#
# WHY --first-parent AND NOT --no-merges ALONE. "The paths this push's own
# non-merge commits touch" reads naturally as `git log --no-merges A..B`, and
# that is WRONG: a commit arriving through the merge is ITSELF a non-merge
# commit newly reachable on this ref, so it is included and the scoped set is
# identical to the unscoped one. Measured while designing this — that
# formulation returned the foreign README right alongside the ledger fragment,
# so the "fix" would have changed nothing while looking correct on any
# same-branch test.
#
# WHY THE ANCESTRY GATE IS NOT OPTIONAL. --first-parent alone is a BYPASS: a
# host can park code on a side branch, merge it with --no-ff and push, and the
# code arrives through the SECOND parent where a first-parent walk cannot see
# it. Measured: a sneaky.rs was invisible to the scoped view while the ledger
# fragments showed. That is not the un-gated union this order knowingly accepts
# (trunk's own content, gated when the coordinator merges into linux-next); it
# is arbitrary unreviewed code taking a lane meant for ledger appends. So the
# scoped view is used ONLY when every merge in the range brings trunk content:
# each merge's second parent must be an ancestor of origin/linux-next. Anything
# else falls back to the FULL net diff, which disqualifies as it always did.
#
# THE DECISION AND THE EMISSION ARE SEPARATE FUNCTIONS ON PURPOSE. The emitter
# is consumed through process substitution, which is a SUBSHELL: a
# LANE_UNION_UNGATED=1 set inside it is discarded, so the marker would silently
# never be written and the stamp would claim a gated union. The decision
# therefore runs in the caller's shell and the caller sets the flag.
_lane_can_scope() { # remote_sha local_sha -> 0 when the merge-scoped view applies
    local remote_sha="$1" local_sha="$2" m p2 merges=0

    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        merges=$((merges + 1))
        p2="$(git rev-parse --verify --quiet "${m}^2" 2>/dev/null)" || return 1
        [[ -n "$p2" ]] || return 1
        # A merge of anything but trunk content cannot be scoped away.
        git merge-base --is-ancestor "$p2" refs/remotes/origin/linux-next 2>/dev/null || return 1
    done < <(git log --merges --format=%H "${remote_sha}..${local_sha}" 2>/dev/null)

    # No merge, nothing to scope away: the net diff already IS this push's own
    # changes. Returning 1 keeps behaviour bit-identical to before this order
    # for every push that does not merge.
    [[ "$merges" -gt 0 ]]
}

_lane_scoped_diff() { # remote_sha local_sha -> "<status>\t<path>" lines
    local remote_sha="$1" local_sha="$2" c
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        git diff --name-status --no-renames "${c}^" "$c" -- 2>/dev/null
    done < <(git log --first-parent --no-merges --format=%H "${remote_sha}..${local_sha}" 2>/dev/null) \
        | LC_ALL=C sort -u
}

attempt_plan_only_lane() {
    local -a files=() srcs=() bases=() issue_bases=()
    local att_seen=0
    LANE_NOTES=()
    LANE_UNION_UNGATED=0

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

        # ORDER 1056-5344: decide HERE, in this shell, whether the merge-scoped
        # view applies — the emitter below runs in a subshell and cannot record it.
        local _scoped=0
        if _lane_can_scope "$remote_sha" "$local_sha"; then
            _scoped=1
            LANE_UNION_UNGATED=1
        fi
        _lane_can_scope_decided() { [[ "$_scoped" -eq 1 ]]; }

        # Net outgoing diff for this ref: what the remote will see change.
        # --no-renames keeps the status alphabet to A/M/D/T: a rename of a
        # fragment decomposes into D+A and the D disqualifies, as it must.
        local status path issue_base=""
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
                plan/issues/?*.md)
                    # Order 889-twhe. The Reduction Engine makes filing a
                    # plan/issues capture a NON-NEGOTIABLE exit condition of
                    # every meta-orchestration cycle, and this lane excluded
                    # exactly that path — so the loop's own mandatory step
                    # forced every finding-bearing cycle onto the full gate, on
                    # every host, every cycle. Measured on calmecacpilli: 4.0
                    # gate re-runs for ONE landed commit carrying two captures,
                    # against 0 for the fragment-only pushes in the same
                    # session. That is a structural tax on precisely the cycles
                    # that produce the most value, and it quietly incentivises
                    # filing LESS. Ruled approved by the coordinator with the
                    # four conditions enforced here and in the validator below.
                    #
                    # A OR M, NEVER D OR T (order 1060-7mmm). This was A only,
                    # by analogy with the fragment arms — but the analogy does
                    # not hold, and the asymmetry it produced points the wrong
                    # way.
                    #
                    # FRAGMENTS ARE IMMUTABLE BY CONSTRUCTION: plan/index.d/
                    # entries are CRDT records whose whole contract is
                    # append-only, so an M there is a corrupted ledger. A
                    # plan/issues capture is PROSE. Nothing about it is
                    # append-only, and a correction to it is the ordinary way it
                    # improves.
                    #
                    # MEASURED on esmeraldinha 2026-09-05, in the same push,
                    # seconds apart, differing only in whether one correction was
                    # included:
                    #   refused: '...smoke-e2e-findings-v56.9.5.1...md' has status
                    #            'M'; only NEW issue captures qualify
                    #   accepted: outgoing diff adds only new plan fragment files
                    # The change was FOUR CHARACTERS — the report cited order
                    # 1029-5vwd, which has no referent; the real one is
                    # 1029-5wvd. The lane accepted the creation of that report
                    # unreviewed and refused the fix to it.
                    #
                    # WHY THIS IS WORTH RELAXING RATHER THAN LIVING WITH. A lane
                    # whose economics favour APPENDING a new record over
                    # CORRECTING an existing one selects for records that read as
                    # settled while carrying something wrong — the failure mode
                    # this fleet keeps finding. The cheap path should be the
                    # honest one. On the night this was filed the finding host
                    # made three corrections to landed or relayed records in one
                    # shift, and this rule taxed every one of them.
                    #
                    # THE BLAST RADIUS IS UNCHANGED, which is the whole argument.
                    # An M here is still validated per-file by
                    # check-issue-citation-convention against the PUSHED bytes,
                    # the same gate the A path runs; the diff it reads is
                    # base..head, so a modification is checked exactly as an
                    # addition is. Prose under plan/issues/ cannot reach the
                    # build and cannot change what the gate validates. An M
                    # ANYWHERE ELSE still takes the full gate — that refusal is
                    # the escape hatch this lane exists to keep shut, and the
                    # fixture asserts it.
                    #
                    # D and T stay refused: a DELETION removes a record the lane
                    # cannot validate the absence of, and a type change is not a
                    # correction.
                    if [[ "$status" != "A" && "$status" != "M" ]]; then
                        echo "plan-only lane: not applicable — '$path' has status '$status' in the outgoing diff; issue captures qualify as new (A) or corrected (M) only (full gate required)" >&2
                        return 1
                    fi
                    # A WORK-QUEUE LEDGER IS A SHARED RECORD, NOT ONE HOST'S
                    # PROSE (order 1013-xm63). 1060-7mmm admits an M anywhere
                    # under plan/issues/ because correcting a report you wrote is
                    # the ordinary way it improves. A work-queue file is
                    # different in kind: several hosts append to the same
                    # document, and a rewrite there can silently drop a sibling's
                    # line — the lane cannot tell a correction from an erasure,
                    # and neither can a reader afterwards.
                    #
                    # So for these files only, the M must be an APPEND. That is
                    # the whole of pirria's case (2026-09-04, a cargo-less host
                    # that could work and report but not comply: the skill's
                    # §6.3 mandates a work-queue line, which is an M by
                    # construction, and the refusal sent it to a full gate it had
                    # no toolchain to run). An append is a record; a rewrite is
                    # not, and it keeps the full gate.
                    #
                    # `git diff` deletion lines, minus the `---` file header. A
                    # pure append has none.
                    case "${path##*/}" in
                        *work-queue*)
                            if [[ "$status" == "M" ]]; then
                                _wq_removed="$(git diff "$remote_sha" "$local_sha" -- "$path" 2>/dev/null \
                                    | grep '^-' | grep -v '^---' | head -3)"
                                if [[ -n "$_wq_removed" ]]; then
                                    echo "plan-only lane: not applicable — '$path' is a work-queue ledger and this edit REMOVES or REWRITES lines, which the lane cannot tell from erasing a sibling host's entry (full gate required)" >&2
                                    printf '%s\n' "$_wq_removed" | sed 's/^/    /' >&2
                                    return 1
                                fi
                            fi
                            ;;
                    esac
                    # DEPTH IS DECIDED EXPLICITLY, not left to a glob. The
                    # Reduction Engine names four classification directories;
                    # a capture lives at the top level or in exactly one of
                    # them. Anything deeper is something else and takes the
                    # full gate.
                    case "${path#plan/issues/}" in
                        */*/*)
                            echo "plan-only lane: not applicable — '$path' is nested more than one directory below plan/issues/ (full gate required)" >&2
                            return 1
                            ;;
                        research/*|exploration/*|enhancement/*|optimization/*)
                            ;;
                        */*)
                            echo "plan-only lane: not applicable — '$path' is not under a Reduction Engine class directory (research/, exploration/, enhancement/, optimization/); full gate required" >&2
                            return 1
                            ;;
                    esac
                    # Prose that is not a capture, mirroring the attestation
                    # arm's README refusal.
                    case "${path##*/}" in
                        README.md|TEMPLATE.md)
                            echo "plan-only lane: not applicable — '$path' is prose, not an issue capture (full gate required)" >&2
                            return 1
                            ;;
                    esac
                    issue_base="$remote_sha"
                    bases+=("")
                    ;;
                *)
                    echo "plan-only lane: not applicable — '$path' is outside plan/index.d/, plan/loop_status.d/, plan/issues/, and plan/mo-full-attestations.d/ (full gate required)" >&2
                    return 1
                    ;;
            esac
            files+=("$path")
            srcs+=("$local_sha")
            # Parallel to files/srcs/bases: empty for every non-issue path, so
            # the validator below can index it without drifting out of step.
            issue_bases+=("$issue_base")
            issue_base=""
        done < <(if _lane_can_scope_decided; then
                     _lane_scoped_diff "$remote_sha" "$local_sha"
                 else
                     git diff --name-status --no-renames "$remote_sha" "$local_sha" -- 2>/dev/null
                 fi)
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
    local have_yq=0 have_plan=0 plan_bin="" plan_why="" plan_not_runnable=""
    command -v yq >/dev/null 2>&1 && have_yq=1
    # Order 721-nyev: `-x` is a CLAIM; running the binary is evidence. On a
    # shared Windows/WSL checkout that test passes on a Linux ELF sitting
    # beside the runnable .exe, after which this lane reported on a validation
    # it never actually performed -- a gate vouching for evidence it did not
    # gather, which is the worst shape in this file.
    . "$(dirname "${BASH_SOURCE[0]}")/../plan-binary-probe.sh"
    plan_bin="$(resolve_plan_binary || true)"
    # ORDER 1060-6fx7: RESOLVED IS NOT THE SAME AS RUNNABLE, and conflating them
    # made this lane blame the DATA for a missing INSTRUMENT.
    #
    # resolve_plan_binary honours an explicit TILLANDSIAS_PLAN_BIN on EXISTENCE
    # alone — deliberately (704-zcgi), so a stub failing the way a STALE binary
    # fails stays distinguishable from an absent one. So `plan_bin` may name a
    # file that cannot execute, and every consumer below then read a non-zero
    # exit as a verdict about the ledger.
    #
    # MEASURED on yoga 2026-09-05: with the override pointed at a binary that
    # dies on exec, three arms of test-pre-push-issue-capture-lane.sh went red
    # with, verbatim:
    #   plan-only lane: validation FAILED — tillandsias-plan check refused the
    #   folded ledger (full gate required)
    # The ledger was sound. That is the 923-ws3r class — "the instrument is
    # missing, not the data" — surviving inside the lane's own validation, and a
    # refusal naming the wrong layer sends the reader to the ledger confidently
    # and they stop when they find nothing wrong there.
    #
    # ONE EXEC, HERE, rather than pattern-matching exit codes at each of the
    # three call sites below: a dynamic-link failure and a genuine refusal are
    # both non-zero, and only running the thing separates them. A binary that
    # cannot answer `capabilities` is not a validator, so the lane treats it as
    # ABSENT — which routes into the existing fail-closed path — and says which
    # of the two it was.
    if [[ -n "$plan_bin" ]]; then
        if plan_why="$("$plan_bin" capabilities 2>&1 >/dev/null)"; then
            have_plan=1
        else
            LANE_NOTES+=("$plan_bin resolved but does NOT run here, so it is not a validator: ${plan_why:-no output}")
            plan_not_runnable="$plan_bin"
            plan_bin=""
        fi
    fi
    # Order 889-twhe: fail closed only when this push actually carries YAML that
    # needs a YAML parser. Before, an issues-only or loop-status-only push was
    # refused for lacking a validator it had nothing to run — the fail-closed
    # rule is right, but it must be scoped to what is being validated, or it
    # refuses pushes on the absence of an irrelevant tool.
    local needs_yaml=0 f
    for f in "${files[@]}"; do
        case "$f" in plan/index.d/*) needs_yaml=1 ;; esac
    done
    if [[ $needs_yaml -eq 1 && $have_yq -eq 0 && $have_plan -eq 0 ]]; then
        # NAME WHICH OF THE TWO IT WAS. "not available" reads as absent, and an
        # operator who can see the file sitting in target/release will not
        # believe it — then look for the wrong problem (1060-6fx7).
        if [[ -n "$plan_not_runnable" ]]; then
            echo "plan-only lane: not applicable — $plan_not_runnable exists but does NOT run here, and yq is absent, so no validator (fail closed; full gate required)" >&2
            echo "  ${plan_why:-}" >&2
        else
            echo "plan-only lane: not applicable — neither yq nor target/release/tillandsias-plan is available to validate fragments (fail closed; full gate required)" >&2
        fi
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
                # ORDER 746-htj9. ONE reader, so the lane's STRICTNESS no longer
                # depends on which tools this host happens to have.
                #
                # What stood here ran both checks under yq and, when yq was
                # absent, delegated to `tillandsias-plan check` with a note. But
                # the delegation could not express the SECOND check, so the
                # map-shape assertion was enforced on hosts with yq and quietly
                # skipped on hosts without — including this Silverblue host,
                # where neither yq NOR ruby is installed. A gate that is stricter
                # on some machines than others is the packet's defect one level
                # up, in the trunk's only gate.
                #
                # `yaml-type` prints yq's own spelling (!!map), so the comparison
                # below is unchanged from the one it replaces.
                if [[ $have_plan -eq 1 ]]; then
                    if ! "$plan_bin" validate-yaml "$blob" >/dev/null 2>&1; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} is not valid YAML (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                    if [[ "$("$plan_bin" yaml-type "$blob" 2>/dev/null)" != '!!map' ]]; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} does not parse to a YAML mapping (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                elif [[ $have_yq -eq 1 ]]; then
                    # Retained only as a transitional tier for a host that has yq
                    # but no built binary. It enforces the SAME two checks, so
                    # neither tier is weaker than the other any more.
                    if ! yq eval '.' "$blob" >/dev/null 2>&1; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} is not valid YAML (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                    if [[ "$(yq eval 'type' "$blob" 2>/dev/null)" != '!!map' ]]; then
                        echo "plan-only lane: validation FAILED — ${files[$i]} does not parse to a YAML mapping (full gate required)" >&2
                        rm -rf "$tmp"; return 1
                    fi
                fi
                ;;
            plan/issues/*)
                # Order 889-twhe, coordinator condition (b): the lane may only
                # accept what it VALIDATES. plan/issues is not gate-free —
                # check-issue-citation-convention.sh (881-29me) is the one gate
                # that reads newly-added issue files, and it must run here and
                # pass, per file, the way fragments are parsed above.
                #
                # It is invoked against the PUSHED commit, not the worktree:
                # TILLANDSIAS_ISSUE_CITATION_HEAD (added by this order) makes it
                # diff base..head instead of base..worktree, so the lane vouches
                # for the bytes the remote receives. Scoped to the single file
                # via _DIR, so one document's violation names that document.
                if [[ ! -x "$REPO_ROOT/scripts/check-issue-citation-convention.sh" && ! -r "$REPO_ROOT/scripts/check-issue-citation-convention.sh" ]]; then
                    echo "plan-only lane: not applicable — scripts/check-issue-citation-convention.sh is unavailable to validate ${files[$i]} (fail closed; full gate required)" >&2
                    rm -rf "$tmp"; return 1
                fi
                if ! TILLANDSIAS_ISSUE_CITATION_DIR="${files[$i]}" \
                     TILLANDSIAS_ISSUE_CITATION_BASE="${issue_bases[$i]}" \
                     TILLANDSIAS_ISSUE_CITATION_HEAD="${srcs[$i]}" \
                     bash "$REPO_ROOT/scripts/check-issue-citation-convention.sh" >/dev/null 2>&1; then
                    echo "plan-only lane: validation FAILED — ${files[$i]} does not pass check-issue-citation-convention (881-29me); full gate required" >&2
                    rm -rf "$tmp"; return 1
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
                    # Order 848-bx2q: a NEW per-host ledger begins with the
                    # fixed '# '-comment header mo-full-attest.sh record
                    # writes, and the grammar below has no comment form — so a
                    # joining host's FIRST attestation always failed here and
                    # paid a full gate for the tool's own output (measured on
                    # lenovinha's rejoin, 2026-08-22). Admit the header:
                    # LEADING comment lines only, then hold every line after
                    # it to the same grammar as an append. A '# ' line after
                    # content still refuses.
                    awk '!started && /^# / { next } { started=1; print }' "$blob" > "$added"
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
        LANE_NOTES+=("target/release/tillandsias-plan absent — fragment schema and status-loss checks skipped (yq tier validated every pushed blob: parse + !!map shape)")
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
    # bash 3.2 (the project floor, and the macOS system bash) treats
    # "${arr[@]}" on an EMPTY array as an unbound variable under `set -u`;
    # bash 4.4 fixed it. LANE_NOTES is empty on the happy path — notes are only
    # appended when a checker was ABSENT and got skipped — so this loop aborted
    # the hook precisely when every check had run, and took the push with it.
    # Guard on the length, which is well-defined for an empty array everywhere.
    local note
    if [ "${#LANE_NOTES[@]}" -gt 0 ]; then
        for note in ${LANE_NOTES[@]+"${LANE_NOTES[@]}"}; do
            echo "plan-only lane: note: $note" >&2
        done
    fi
    # ORDER 1056-5344: RECORD THE GATE DEBT rather than imply the lane gated it.
    # When the lane was taken over a mandated merge, the pushed head is a UNION
    # of two sides that were each green separately and were never gated
    # TOGETHER — the 754-kptj shape. The lane validated this push's own
    # fragments; it did not build the union. Write that down where the
    # coordinator's land can read it, so the debt is a fact on disk instead of
    # an inference someone has to make from the branch topology.
    if [ "${LANE_UNION_UNGATED:-0}" -eq 1 ]; then
        local _um; _um="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-union-ungated"
        printf '%s %s\n' "$(git rev-parse HEAD 2>/dev/null)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$_um" 2>/dev/null || true
        echo "plan-only lane: this head is an UN-GATED UNION (scoped past a merge of origin/linux-next);" >&2
        echo "plan-only lane: recorded in $_um — the coordinator's land gates it, this lane did not" >&2
    fi
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
                # ORDER 864-q7dm — NAME WHAT CHANGED, because "re-run it" is
                # sometimes ACTIVELY WRONG ADVICE.
                #
                # This host is told to run long-horizon background work, and
                # the stamp assumes the tree holds still. Those instructions
                # conflict. Measured 2026-08-23: a band measurement appending a
                # TSV inside the checkout made every push fail here, and the
                # re-run the message recommends stamps a tree that changes
                # again before the push completes — so the advice cannot
                # terminate. The cycle could not push ANY work, including work
                # entirely unrelated to the job, for as long as the job ran.
                #
                # Untracked does not exempt a path: the stamp covers
                # `ls-files --cached --others`, so a file APPEARING or GROWING
                # invalidates it exactly as a tracked edit does.
                #
                # Naming the paths turns a puzzle into a decision. mtime
                # against the stamp file is the cheap signal — it needs no
                # per-path digests and it points straight at a live writer.
                _gs="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-gate-stamp"
                _changed=""
                if [[ -f "$_gs" ]]; then
                    _changed="$(git ls-files -z --cached --others --exclude-standard 2>/dev/null \
                        | xargs -0 -r -I{} sh -c '[ -f "{}" ] && [ "{}" -nt "'"$_gs"'" ] && printf "%s\n" "{}"' 2>/dev/null \
                        | head -12)"
                fi
                if [[ -n "$_changed" ]]; then
                    _n="$(printf '%s\n' "$_changed" | wc -l | tr -d ' ')"
                    refuse "the tree changed since ./build.sh --check last passed" \
                           "The gate validated a different tree than the one you are pushing." \
                           "" \
                           "CHANGED SINCE THE GATE RAN (${_n} path(s), newest-first by mtime):" \
                           "$(printf '  %s\n' $_changed)" \
                           "" \
                           "IF ONE OF THOSE IS A BACKGROUND JOB STILL WRITING, re-running the" \
                           "gate will not help — it stamps a tree that changes again before the" \
                           "push lands (864-q7dm). Move the in-progress output OUT of the" \
                           "checkout instead; a running redirect holds the file by inode, so" \
                           "\`mv\` is safe mid-run and the job keeps appending:" \
                           "  mv <path> target/   # target/ is gitignored" \
                           "" \
                           "Otherwise the change is yours and the gate is right:" \
                           "  ./build.sh --check"
                else
                    refuse "the tree changed since ./build.sh --check last passed" \
                           "The gate validated a different tree than the one you are pushing." \
                           "(No path is newer than the stamp — the change is a deletion, a mode" \
                           "change, or a same-mtime rewrite.)" \
                           "Re-run it:" \
                           "  ./build.sh --check"
                fi
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
