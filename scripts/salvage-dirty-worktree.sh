#!/usr/bin/env bash
# @trace order:872-c9nd
#
# salvage-dirty-worktree.sh — ORDER 872-c9nd; collision handling 874-w2gc.
#
# Push a dirty worktree's CONTENT to origin before refusing the cycle, so that
# work which the refusal protects cannot then be deleted by anything else.
#
# WHY THIS EXISTS. On 2026-08-23 a host wedged with 16 modified paths and one
# untracked litmus file belonging to two claimed packets. Three consecutive
# cycles refused the dirty tree, verified all 17 paths byte-identical to their
# boundary snapshots, and wrote increasingly detailed prose about a diff nobody
# preserved. On 2026-08-24T06:09Z the checkout was replaced by a fresh clone.
# Four hours of finished work are unrecoverable; the untracked file's name
# appears in no commit on any branch.
#
# The boundary guard did its job perfectly and protected a directory that
# someone then deleted wholesale. A guard that forbids the AGENT from touching
# the work does not forbid anything else from touching it. Prose describing a
# diff is not a copy of it.
#
# IT MUST NOT MUTATE THE WORKTREE, because the whole point is that this runs on
# work the cycle has been forbidden to alter. It therefore uses a TEMPORARY
# INDEX (GIT_INDEX_FILE) and plumbing only:
#
#   cp .git/index -> $tmp/index      start from what is already staged
#   git add -A                       stages into the TEMP index; worktree and
#                                    real index untouched
#   git write-tree / git commit-tree build the object graph directly
#   git push <sha>:refs/heads/salvage/<host>/<date>-<slug>
#
# No checkout, no stash, no add against the real index, no branch switch. The
# only lasting effect is objects on the remote.
#
# `salvage/<host>/<yyyymmdd>-<slug>` is an EXISTING accepted ref grammar whose
# YAML gate is deliberately exempt (see scripts/test-pre-receive-yaml-gate.sh),
# precisely so a half-edited tree can be pushed. It existed and nothing used it.
#
# Verdict, one line on stdout:
#   ok:salvaged:<ref>:<sha>      content is on origin
#   ok:salvage-not-needed        the worktree is clean; nothing to preserve
#   fail:salvage:<reason>        exit 1 — do NOT proceed to a refusal that
#                                discards the tree on the strength of a copy
#                                that does not exist
set -uo pipefail

# TILLANDSIAS_SALVAGE_ROOT: test seam (874-w2gc) so the fixture can salvage a
# scratch repo instead of this checkout. Unset in production.
ROOT="${TILLANDSIAS_SALVAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

SLUG="${1:-dirty-start}"
HOST="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$HOST" ] || HOST="unknown"
STAMP="$(date -u +%Y%m%d)"
REF="refs/heads/salvage/${HOST}/${STAMP}-${SLUG}"

# 874-w2gc exit criterion 2: two salvages the same host/day must BOTH land.
# The date-keyed name collides on the second same-day salvage and the push
# dies non-fast-forward — measured during 874-s8vf's own bring-up. Probe the
# remote first and uniquify with the UTC time-of-day; the base name stays
# stable for the common one-salvage day so refs remain human-guessable.
if git ls-remote --exit-code origin "$REF" >/dev/null 2>&1; then
    REF="${REF}-$(date -u +%H%M%S)"
fi

if [ -z "$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" ]; then
    echo "ok:salvage-not-needed"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-salvage.XXXXXX")" || {
    echo "fail:salvage:no-tmpdir"; exit 1
}
trap 'rm -rf "$tmp"' EXIT INT TERM

git_dir="$(git rev-parse --git-dir 2>/dev/null)" || { echo "fail:salvage:not-a-git-repo"; exit 1; }

# Seed the temp index from the real one so already-staged content is preserved
# exactly. A missing index (fresh clone, nothing staged) is fine — git will
# create the temp one on first add.
if [ -f "$git_dir/index" ]; then
    cp "$git_dir/index" "$tmp/index" || { echo "fail:salvage:index-copy"; exit 1; }
fi
export GIT_INDEX_FILE="$tmp/index"

# -A picks up modifications, deletions and untracked files. It honours
# .gitignore, which is correct: build caches are not work.
if ! git add -A 2>"$tmp/err"; then
    echo "fail:salvage:add:$(head -1 "$tmp/err" 2>/dev/null | tr -d '\n' | cut -c1-80)"
    exit 1
fi

tree="$(git write-tree 2>/dev/null)" || { echo "fail:salvage:write-tree"; exit 1; }
head_sha="$(git rev-parse HEAD 2>/dev/null)" || { echo "fail:salvage:no-head"; exit 1; }

msg="salvage(${HOST}): dirty worktree preserved before a cycle refusal

Captured by scripts/salvage-dirty-worktree.sh (872-c9nd) from a worktree the
cycle was forbidden to modify. Parent is the HEAD the dirt sat on. This is a
COPY for recovery, not a proposal to merge.

git status at capture:
$(git --no-optional-locks status --porcelain=v1 --untracked-files=all 2>/dev/null | head -60)"

# 934-7jd4 (found via 872-c9nd's own fixture): salvage must NEVER fail for
# want of a git identity. A host with no user.email configured auto-derives
# one from its FQDN — which works on bare metal and hard-fails inside a
# container, where the hostname yields 'user@toolbx.(none)' and commit-tree
# exits 128. On the refusal path that means the copy justifying the refusal
# never exists, which is the exact loss 872-c9nd was written to prevent. An
# explicit fallback identity is strictly better than no salvage; the ref
# name already carries the real host.
if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME="salvage" GIT_AUTHOR_EMAIL="salvage@${HOST}" \
           GIT_COMMITTER_NAME="salvage" GIT_COMMITTER_EMAIL="salvage@${HOST}"
fi
# stderr is CAPTURED into the verdict, not discarded: a swallowed cause here
# cost an evening of guesses elsewhere the same day this line was fixed.
commit="$(printf '%s' "$msg" | git commit-tree "$tree" -p "$head_sha" 2>"$tmp/cterr")" \
    || { echo "fail:salvage:commit-tree:$(head -1 "$tmp/cterr" 2>/dev/null | tr -d '\n' | cut -c1-80)"; exit 1; }

if ! git push --quiet origin "${commit}:${REF}" 2>"$tmp/perr"; then
    echo "fail:salvage:push:$(head -1 "$tmp/perr" 2>/dev/null | tr -d '\n' | cut -c1-80)"
    exit 1
fi

echo "ok:salvaged:${REF}:${commit}"
