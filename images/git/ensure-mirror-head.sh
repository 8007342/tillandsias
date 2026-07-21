#!/bin/sh
# @trace spec:git-mirror-service
# ensure-mirror-head <bare-mirror-dir> [preferred-branch]
#
# A bare mirror's HEAD must always name a real, cloneable head. `git init
# --bare` leaves HEAD -> refs/heads/master (Alpine git default), the seed
# fetch writes refs/heads/main + work branches, and nothing repointed HEAD —
# upstream has no master, so every `git clone git://tillandsias-git/<p>`
# exited 0 with "remote HEAD refers to nonexistent ref", an EMPTY working
# tree, and the order-452 fail-loud assert crashed every harness launch
# (plan/issues/mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md).
#
# Resolution order for the repaired HEAD:
#   1. the preferred branch ($2, else $TILLANDSIAS_PROJECT_DEFAULT_BRANCH —
#      the launcher passes the host checkout's current branch so agents land
#      on the operator's working branch, not GitHub's default);
#   2. upstream's default branch (git ls-remote --symref origin HEAD);
#   3. main;
#   4. the first local head.
#
# Exit codes: 0 = HEAD already valid or repaired; 3 = no local heads yet
# (mirror still seeding or upstream empty — caller treats as non-fatal and
# retries after the next seed/fetch); anything else = git failure.
#
# POSIX sh only (runs under Alpine busybox sh and in offline fixtures).

mirror="$1"
prefer="${2:-${TILLANDSIAS_PROJECT_DEFAULT_BRANCH:-}}"

if [ -z "$mirror" ] || [ ! -d "$mirror" ]; then
    echo "ensure-mirror-head: usage: ensure-mirror-head <bare-mirror-dir> [preferred-branch]" >&2
    exit 2
fi

# HEAD already resolves to a commit on a real head: nothing to do.
if git -C "$mirror" rev-parse --quiet --verify HEAD >/dev/null 2>&1; then
    exit 0
fi

target=""
if [ -n "$prefer" ] && git -C "$mirror" show-ref --verify --quiet "refs/heads/$prefer"; then
    target="$prefer"
fi
if [ -z "$target" ]; then
    # Upstream symref line: "ref: refs/heads/<name>\tHEAD".
    sym="$(git -C "$mirror" ls-remote --symref origin HEAD 2>/dev/null \
        | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p')"
    if [ -n "$sym" ] && git -C "$mirror" show-ref --verify --quiet "refs/heads/$sym"; then
        target="$sym"
    fi
fi
if [ -z "$target" ] && git -C "$mirror" show-ref --verify --quiet refs/heads/main; then
    target="main"
fi
if [ -z "$target" ]; then
    target="$(git -C "$mirror" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | head -n 1)"
fi

if [ -z "$target" ]; then
    echo "ensure-mirror-head: no local heads in $mirror (still seeding or upstream empty); HEAD left as-is" >&2
    exit 3
fi

git -C "$mirror" symbolic-ref HEAD "refs/heads/$target" || exit 1
echo "ensure-mirror-head: HEAD -> refs/heads/$target ($mirror)"
exit 0
