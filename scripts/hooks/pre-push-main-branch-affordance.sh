#!/usr/bin/env bash
# pre-push-main-branch-affordance.sh — refuse a direct push to main, and SAY
# WHAT TO DO INSTEAD.
#
# WHY THIS EXISTS, and it is not the refusal that was missing.
#
# Pushing to main was already impossible: main carries server-side branch
# protection with enforce_admins (order 476), so the push left the machine,
# crossed the network, and came back as a GitHub rejection with no local
# context and no remedy. An in-forge agent hit exactly this and lost a cycle to
# it — the forge seeds its branch from the HOST CHECKOUT'S CURRENT BRANCH
# (read_host_project_current_branch -> TILLANDSIAS_FORGE_SEED_BRANCH,
# images/default/lib-common.sh:3951), so a host left parked on main silently
# pins every forge launched afterwards to main. The agent could not see why,
# because the only message it got was the remote's.
#
# THE OPERATOR'S RULE, 2026-08-23: every error should carry a recommendation.
# Guardrails paraphrased across orchestration instructions rot and are not read
# at the moment of failure; an affordance AT the point of refusal is read
# exactly then, by whoever is blocked, and needs no one to have memorised
# anything. This file is that rule applied to the one refusal that was
# arriving from a server.
#
# Same shape as the other affordances landing this week: the expert layer's
# Intended/Compatible/Discouraged/Prohibited (853-6gz3), the merge affordances
# on packet closure (863-7mhg), and the fold's "NO SUCH PACKET, so this event
# is attached to nothing" replacing "that packet is not in the fold". A refusal
# that names only the rule teaches nothing.
#
# Verdict grammar (stdout, one line):
#   ok:main-branch-affordance            nothing targets main
#   blocked:main-branch-affordance       a ref targets main; remedy on stderr
set -uo pipefail

# git feeds pre-push hooks "<local ref> <local sha> <remote ref> <remote sha>"
# on stdin. Read it if present; when invoked standalone (fixtures) there is
# nothing to read and nothing to refuse.
targets_main=0
while read -r _local_ref _local_sha remote_ref _remote_sha; do
    [ -n "${remote_ref:-}" ] || continue
    case "$remote_ref" in
        refs/heads/main) targets_main=1 ;;
    esac
done

if [ "$targets_main" -eq 0 ]; then
    echo "ok:main-branch-affordance"
    exit 0
fi

# WHICH branch to recommend depends on where you are, and guessing wrong is
# worse than not guessing: sending a Windows host to linux-next would breach
# the platform-branch discipline this project runs on.
_suggest="linux-next"
_where="this host"
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    _where="the forge"
    _suggest="linux-next"
elif [ -n "${OS:-}" ] && [ "${OS:-}" = "Windows_NT" ]; then
    _where="this Windows host"
    _suggest="windows-next"
else
    case "$(uname -s 2>/dev/null)" in
        Darwin) _where="this macOS host"; _suggest="osx-next" ;;
        MINGW* | MSYS* | CYGWIN*) _where="this Windows host"; _suggest="windows-next" ;;
    esac
fi

echo "blocked:main-branch-affordance"
{
    echo "main is not pushable from here, and it never was — it carries"
    echo "server-side branch protection with enforce_admins (order 476), so this"
    echo "push would have travelled to GitHub only to be rejected there."
    echo
    echo "  WHAT TO DO: work on '${_suggest}' from ${_where}."
    echo "    git branch --show-current      # confirm where you are"
    echo "    git checkout ${_suggest}"
    echo
    echo "  IF YOU ARE IN A FORGE and did not choose main: the forge seeds its"
    echo "  branch from the HOST checkout's current branch, so a host left parked"
    echo "  on main pins every forge launched after it (order 531). Fix the host"
    echo "  checkout, not just this one."
    echo
    echo "  main only ever advances through a PR, which the"
    echo "  merge-to-main-and-release skill opens. It is a release decision, not"
    echo "  a push."
} >&2
exit 1
