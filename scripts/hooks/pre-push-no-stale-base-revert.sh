#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1000-rqmx
#
# Refuse a push whose diff DELETES files the outgoing commits never touched.
#
# THE FAILURE THIS EXISTS FOR, found by esme-tillandsias-wsl2 across a session
# of being unable to push, and relayed minutes before the 2026-09-04 fleet
# restart because it would otherwise have died with the container.
#
# THE COMMIT IS INNOCENT AND THE DIFF IS NOT. Their commit was one file, 3475
# insertions, entirely their own work. But it sat on a base that went stale
# while the trunk advanced beneath it, and `git diff origin/linux-next..HEAD`
# grew as it aged:
#
#     ~19:00Z  108 files, ~6,900 deletions
#     ~04:00Z  139 files,  5,096 deletions
#
# Pushing it would have reverted work from six other hosts. Nothing warned.
#
# WHY THE EXISTING GATES DO NOT CATCH IT. Every attempt was `--no-verify`, and
# legitimately so: the local gate had already passed, and the MIRROR was
# refusing at the relay, so the gate was not the thing saying no. A guard that
# only runs when someone remembers to let it is not the fix — which is the same
# reasoning that made the landing tool worth more than a documented sequence.
#
# THE CHECK. For each ref being pushed:
#   touched  = every path the OUTGOING COMMITS themselves changed
#              (git log --name-only over remote..local)
#   deleted  = every path the PUSH'S DIFF removes
#              (git diff --name-status remote..local, status D)
#   violation = deleted MINUS touched
#
# A deletion a commit actually made appears in both sets and passes. A deletion
# that exists only because the base is stale appears in `deleted` and never in
# `touched`, because no outgoing commit ever mentioned that file. That
# difference is the whole guard, and it does not need to know what "stale" means.
#
# Verdict grammar, one line on stdout:
#   ok:no-stale-base-revert:<n> ref(s) checked      exit 0
#   blocked:stale-base-revert:<ref>:<n> file(s)     exit 1
set -uo pipefail

ZERO="0000000000000000000000000000000000000000"
checked=0

while read -r _lref lsha rref rsha; do
    [ -n "${lsha:-}" ] || continue
    # Branch deletion: nothing is being added, nothing to revert.
    case "$lsha" in "$ZERO") continue ;; esac
    # NEW remote ref: there is no remote history to revert, and diffing against
    # the zero sha is meaningless. A fresh branch is exactly the salvage case,
    # which must never be blocked.
    case "$rsha" in "$ZERO"|"") continue ;; esac
    git cat-file -e "$rsha^{commit}" 2>/dev/null || continue

    checked=$((checked + 1))

    # Paths the outgoing commits actually changed. --name-only over a range
    # lists each commit's own changes, so a file this branch deleted on purpose
    # IS here; a file only the trunk touched is NOT.
    touched="$(git log --format= --name-only "$rsha..$lsha" 2>/dev/null | sort -u)"
    # Paths this push would delete relative to the CURRENT remote tip.
    deleted="$(git diff --name-status "$rsha..$lsha" 2>/dev/null | awk '$1 == "D" { print $2 }' | sort -u)"

    [ -n "$deleted" ] || continue

    unexplained="$(comm -23 <(printf '%s\n' "$deleted") <(printf '%s\n' "$touched"))"
    n="$(printf '%s\n' "$unexplained" | grep -c . || true)"
    [ "${n:-0}" -gt 0 ] || continue

    echo "blocked:stale-base-revert:${rref:-unknown}:${n} file(s)"
    {
        echo ""
        echo "  This push would DELETE ${n} file(s) that none of its own commits touched."
        echo "  That is what a stale base looks like: the branch is fine, and the DIFF"
        echo "  against the current remote reverts whatever landed underneath it."
        echo ""
        echo "  Files that would be reverted (first 20):"
        printf '%s\n' "$unexplained" | grep . | head -20 | sed 's/^/    /'
        [ "$n" -gt 20 ] && echo "    … and $((n - 20)) more"
        echo ""
        echo "  Fix by rebasing or merging onto the current remote, then pushing again:"
        echo "      git fetch origin && git merge origin/${rref#refs/heads/}"
        echo "  The SAME commits on a current base push cleanly — the commits are not"
        echo "  the problem, their base is."
        echo ""
        echo "  ON --no-verify: it bypasses this guard, and that is deliberate. Git"
        echo "  offers no hook that cannot be skipped, so pretending otherwise would"
        echo "  be false comfort. What --no-verify cannot do is make this SILENT: the"
        echo "  refusal above names the files, so anyone who overrides it is choosing"
        echo "  to revert work it listed rather than never being told (order 1000-rqmx)."
    } >&2
    exit 1
done

echo "ok:no-stale-base-revert:${checked} ref(s) checked"
