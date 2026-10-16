#!/bin/sh
# @trace order:1264-s4id, order:1217-54vw
#
# Forge-side PUSH CAPABILITY: can this forge push to the repository it was
# launched for? Reported as a CAPABILITY with its affordance, never as a gate
# (operator ruling 2026-09-18 on 1217-54vw): "A READ-ONLY TOKEN IS NOT AN
# ERROR, but a supported scenario." A forge with a read-only token still
# launches and still does the work that needs no push.
#
# WHERE THE ANSWER COMES FROM. The forge's `origin` is the enclave git mirror,
# and the mirror already runs the push dry-run against the real upstream at its
# start and on every reconcile (images/git/probe-upstream-auth.sh), publishing
#   refs/tillandsias/upstream-auth/<state>[/<reason>]/<epoch>
# This reads that ref through `git ls-remote origin`, so the question is asked
# at forge launch, about exactly the repository this forge was launched for,
# with no second probe and no credential in the forge.
#
# WHY A SEPARATE FILE: lib-common.sh cannot be sourced outside the forge image,
# so this helper has no import-time side effects and is run directly, with a
# stub `git`, by scripts/test-push-capability.sh.
#
# PINNED GRAMMAR — the machine line agents branch on:
#   push_state=<can-push|read-only|revoked|sso-required|no-credential|local-only|unknown> push_reason=<name|->
# and the human line (TILLANDSIAS_PUSH_LINE) with the affordance.
# State vocabulary (CLOSED SET), from the mirror's verdict:
#   can-push       authorized
#   read-only      denied/permission — the token authenticates but cannot push
#                  here: SUPPORTED, the forge works locally
#   revoked        denied/unauthenticated or agent-unauthenticated — LOUD
#   sso-required   denied/sso — the token needs SSO authorization for the org
#   no-credential  Vault holds no GitHub credential
#   local-only     no upstream: pushes stay in the enclave mirror
#   unknown        no verdict yet (probe-pending), the mirror unreachable
#                  (mirror-unreachable) or the mirror's own error (probe-error)
# TILLANDSIAS_PUSH_LOUD=1 for the states a user must be told about at launch
# (read-only, revoked, sso-required, no-credential).

tillandsias_push_capability() {
    _pc_dir="${1:-.}"
    _pc_repo="${2:-this repository}"
    TILLANDSIAS_PUSH_STATE="unknown"
    TILLANDSIAS_PUSH_REASON="probe-pending"
    TILLANDSIAS_PUSH_LOUD=0
    _pc_out="$(git -C "$_pc_dir" ls-remote origin 'refs/tillandsias/upstream-auth/*' 2>/dev/null)"
    _pc_rc=$?
    if [ "$_pc_rc" -ne 0 ]; then
        TILLANDSIAS_PUSH_REASON="mirror-unreachable"
    else
        # The newest verdict: the largest trailing epoch. The mirror keeps one
        # ref, but never assume it.
        _pc_ref="$(printf '%s\n' "$_pc_out" \
            | sed -n 's#^[0-9a-f]*[[:space:]]*refs/tillandsias/upstream-auth/##p' \
            | awk -F/ 'NF >= 2 { print $NF "\t" $0 }' | sort -n | tail -n 1 | cut -f2)"
        _pc_state="${_pc_ref%%/*}"
        _pc_sub="$(printf '%s' "$_pc_ref" | cut -d/ -f2)"
        case "$_pc_state" in
            authorized) TILLANDSIAS_PUSH_STATE="can-push"; TILLANDSIAS_PUSH_REASON="-" ;;
            denied)
                case "$_pc_sub" in
                    permission) TILLANDSIAS_PUSH_STATE="read-only"; TILLANDSIAS_PUSH_REASON="permission" ;;
                    unauthenticated) TILLANDSIAS_PUSH_STATE="revoked"; TILLANDSIAS_PUSH_REASON="unauthenticated" ;;
                    sso) TILLANDSIAS_PUSH_STATE="sso-required"; TILLANDSIAS_PUSH_REASON="sso" ;;
                    *) TILLANDSIAS_PUSH_STATE="unknown"; TILLANDSIAS_PUSH_REASON="denied-unclassified" ;;
                esac ;;
            agent-unauthenticated) TILLANDSIAS_PUSH_STATE="revoked"; TILLANDSIAS_PUSH_REASON="agent-unauthenticated" ;;
            no-credential) TILLANDSIAS_PUSH_STATE="no-credential"; TILLANDSIAS_PUSH_REASON="-" ;;
            local-only) TILLANDSIAS_PUSH_STATE="local-only"; TILLANDSIAS_PUSH_REASON="-" ;;
            error) TILLANDSIAS_PUSH_STATE="unknown"; TILLANDSIAS_PUSH_REASON="probe-error" ;;
            *) TILLANDSIAS_PUSH_STATE="unknown"; TILLANDSIAS_PUSH_REASON="probe-pending" ;;
        esac
    fi
    case "$TILLANDSIAS_PUSH_STATE" in
        can-push)
            TILLANDSIAS_PUSH_LINE="push: can push to ${_pc_repo}" ;;
        read-only)
            TILLANDSIAS_PUSH_LOUD=1
            TILLANDSIAS_PUSH_LINE="push: read-only — this token is read only for ${_pc_repo}. That is supported: local builds, local containers, locally served content and local commits all still work; only pushing does not. To push, give the token Contents: Read and write on ${_pc_repo} (https://github.com/settings/personal-access-tokens), then sign in again." ;;
        revoked)
            TILLANDSIAS_PUSH_LOUD=1
            TILLANDSIAS_PUSH_LINE="push: REVOKED — the GitHub credential is no longer accepted (${TILLANDSIAS_PUSH_REASON}), so nothing can be pushed to ${_pc_repo}. This is not a repository-permission problem: sign in to GitHub again from the tray (GitHub Login)." ;;
        sso-required)
            TILLANDSIAS_PUSH_LOUD=1
            TILLANDSIAS_PUSH_LINE="push: sso-required — the token is not authorized for the organization's single sign-on, so ${_pc_repo} refuses pushes. Authorize it for SSO at https://github.com/settings/tokens, then sign in again." ;;
        no-credential)
            TILLANDSIAS_PUSH_LOUD=1
            TILLANDSIAS_PUSH_LINE="push: no-credential — no GitHub sign-in is stored, so nothing can be pushed to ${_pc_repo}. Sign in from the tray (GitHub Login); everything local still works." ;;
        local-only)
            TILLANDSIAS_PUSH_LINE="push: local-only — ${_pc_repo} has no upstream; pushes are kept in the enclave mirror." ;;
        *)
            TILLANDSIAS_PUSH_LINE="push: unknown (${TILLANDSIAS_PUSH_REASON}) — the mirror has not reported whether ${_pc_repo} accepts pushes; a push will say so if it does not." ;;
    esac
    TILLANDSIAS_PUSH_MACHINE="push_state=${TILLANDSIAS_PUSH_STATE} push_reason=${TILLANDSIAS_PUSH_REASON}"
    return 0
}

# Branch-level capability (1264-s4id outcome A, coordinator ruling 2026-10-16):
# does THIS project's own push discipline refuse the branch the forge starts
# on? Asked of the discipline itself, `tillandsias-plan discipline check-ref`,
# the same decision the installed pre-push hook makes (1443-sb9b), never a
# hard-coded "main": the refused set is whatever the project's seed
# (.tillandsias/branch-discipline.yaml) says, so a seed change is followed.
#   push_branch=<free|ok|refused|unknown> push_branch_reason=<name|->
#   free     no seed: level 0, nothing is ever refused
#   ok       the discipline accepts a push of this branch (reason `warn` when
#            it accepts with a warning: a rule not yet backed by origin)
#   refused  it refuses it; TILLANDSIAS_PUSH_BRANCH_LINE says "move away from
#            <branch>" and carries the seed's own remedy
#   unknown  no-plan-binary (a seed but nothing to ask) | no-branch
#            | seed-invalid (the discipline refused the seed itself) | no-verdict
# GitHub branch protection is NOT asked here (that needs a token; follow-up row).
tillandsias_push_branch() {
    _pb_dir="${1:-.}"
    _pb_branch="${2:-}"
    TILLANDSIAS_PUSH_BRANCH="unknown"
    TILLANDSIAS_PUSH_BRANCH_REASON="-"
    TILLANDSIAS_PUSH_BRANCH_LINE=""
    if [ ! -f "$_pb_dir/.tillandsias/branch-discipline.yaml" ]; then
        TILLANDSIAS_PUSH_BRANCH="free"
        TILLANDSIAS_PUSH_BRANCH_MACHINE="push_branch=free push_branch_reason=-"
        return 0
    fi
    if [ -z "$_pb_branch" ] || [ "$_pb_branch" = "HEAD" ]; then
        TILLANDSIAS_PUSH_BRANCH_REASON="no-branch"
    else
        _pb_plan="${TILLANDSIAS_PLAN_BIN:-}"
        [ -n "$_pb_plan" ] || _pb_plan="$(command -v tillandsias-plan 2>/dev/null)"
        if [ -z "$_pb_plan" ] || [ ! -x "$_pb_plan" ]; then
            TILLANDSIAS_PUSH_BRANCH_REASON="no-plan-binary"
        else
            _pb_out="$("$_pb_plan" discipline check-ref "refs/heads/$_pb_branch" --root "$_pb_dir" 2>&1)"
            _pb_verdict="$(printf '%s\n' "$_pb_out" | head -n 1)"
            case "$_pb_verdict" in
                refused:discipline:*)
                    TILLANDSIAS_PUSH_BRANCH="refused"
                    TILLANDSIAS_PUSH_BRANCH_REASON="$(printf '%s' "$_pb_verdict" | cut -d: -f3)"
                    _pb_remedy="$(printf '%s\n' "$_pb_out" | sed -n 's/^remedy: //p' | head -n 1)"
                    TILLANDSIAS_PUSH_BRANCH_LINE="push: move away from ${_pb_branch} — this project's push discipline refuses it (${TILLANDSIAS_PUSH_BRANCH_REASON}). ${_pb_remedy}" ;;
                refused:discipline-seed:*)
                    TILLANDSIAS_PUSH_BRANCH_REASON="seed-invalid" ;;
                ok:discipline:*|advised:discipline:*)
                    TILLANDSIAS_PUSH_BRANCH="ok" ;;
                warn:discipline:*)
                    # The rule is not yet backed by what origin shows, so the
                    # hook warns and lets the push through.
                    TILLANDSIAS_PUSH_BRANCH="ok"
                    TILLANDSIAS_PUSH_BRANCH_REASON="warn" ;;
                *)
                    TILLANDSIAS_PUSH_BRANCH_REASON="no-verdict" ;;
            esac
        fi
    fi
    TILLANDSIAS_PUSH_BRANCH_MACHINE="push_branch=${TILLANDSIAS_PUSH_BRANCH} push_branch_reason=${TILLANDSIAS_PUSH_BRANCH_REASON}"
    return 0
}
