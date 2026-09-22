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
#   ok:salvaged:<ref>:<sha>       content is on origin
#   ok:salvaged-local:<ref>:<sha> content is in THIS repo and NOT on origin
#                                 (order 1103-i7xq — the push failed; the copy
#                                 exists and survives a re-clone only if
#                                 somebody pushes that ref). Exit 0: a local
#                                 copy is a real copy, and treating it as a
#                                 failure is how a host abandons the one thing
#                                 standing between it and 872-c9nd.
#   ok:salvaged-commits:<ref>:<sha> (1146-8j7i) the worktree was clean but
#                                 HEAD itself was not reachable from any
#                                 origin ref — a finished, gate-passing commit
#                                 sitting nowhere origin can see. HEAD is
#                                 pushed to the salvage ref by the identical
#                                 path used below; a push failure here still
#                                 reports ok:salvaged-local, same grammar as
#                                 the dirty-tree case.
#   skip:salvage:unstageable:<path> (1146-8j7i) one line, on stdout, per path
#                                 the substrate refused to stage (the
#                                 ENOSYS/EOPNOTSUPP family — e.g. a dangling
#                                 symlink under Git for Windows, whose MSYS symlink emulation has nothing to copy; WSL git on the same path stages it). The salvage proceeds with
#                                 every other path; it never fails the whole
#                                 run for one path it cannot open.
#   ok:salvage-not-needed         the worktree is clean AND HEAD is reachable
#                                 from an origin ref; nothing to preserve
#   fail:salvage:<reason>         exit 1 — do NOT proceed to a refusal that
#                                 discards the tree on the strength of a copy
#                                 that does not exist
set -uo pipefail

# TILLANDSIAS_SALVAGE_ROOT: test seam (874-w2gc) so the fixture can salvage a
# scratch repo instead of this checkout. Unset in production.
ROOT="${TILLANDSIAS_SALVAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

# USAGE GUARD (2026-09-14): the slug used to be `${1:-dirty-start}` with no
# check, so `--help` was taken AS the slug and, since the clean-tree extension
# (1146-8j7i), every probe of this script for usage pushed the current HEAD to
# salvage/<host>/<stamp>---help — sixteen such refs from three hosts in one
# day, each demanding a ledger line and a marked deletion. An empty argument
# keeps the documented default; -h, --help or any leading-dash argument prints
# the usage and exits 2 pushing nothing; a slug is [A-Za-z0-9._-]+.
_slug_usage() {
    cat >&2 <<'USAGE'
usage: scripts/salvage-dirty-worktree.sh [<slug>]
  Pushes a COPY of this worktree's dirt (or its unpushed HEAD when the tree is
  clean) to refs/heads/salvage/<host>/<yyyymmdd>-<slug> on origin, touching
  nothing in the worktree. <slug> defaults to dirty-start; it must match
  [A-Za-z0-9._-]+ and must not start with a dash. Verdicts:
  ok:salvaged:<ref>:<sha> | ok:salvaged-commits:<ref>:<sha> |
  ok:salvaged-local:<ref>:<sha> | ok:salvage-not-needed | skip:salvage:…
USAGE
}
case "${1:-}" in
    -h|--help|-*) _slug_usage; echo "refused:salvage:usage:${1:-} is not a slug (nothing pushed)"; exit 2 ;;
esac
SLUG="${1:-dirty-start}"
case "$SLUG" in
    *[!A-Za-z0-9._-]*) _slug_usage; echo "refused:salvage:bad-slug:$SLUG (nothing pushed)"; exit 2 ;;
esac
# HOST RESOLUTION GOES THROUGH THE ONE RESOLVER, AND REFUSES RATHER THAN
# INVENTING (order 1337-3tk6). This used to be `hostname -s` with a literal
# "unknown" fallback. The forge image does not ship a `hostname` executable, so
# every ref this script pushed from a forge was attributed to `salvage/unknown/`
# — six such refs across nineteen days, every one forge-shaped, against roughly
# a hundred host-attributed refs from bare-metal hosts.
#
# THE FALLBACK WAS A PLACEHOLDER, NOT A SECOND RESOLVER. It did not try another
# source and it did not refuse; it minted a plausible-looking name and pushed
# under it. Meanwhile $HOSTNAME, /etc/hostname and `uname -n` all answered
# correctly in the same container.
#
# scripts/agent-identity.sh already solved exactly this, as order 743-mgf3, for
# exactly this reason — its `node-name` probe is hostname -s -> hostname ->
# uname -n -> /etc/hostname, domain-stripped and lowercased with bash builtins,
# and it is already shared with scripts/mo-full-attest.sh's host label. This
# script simply never adopted it. Calling it is the fix; a second hand-rolled
# chain would be a third copy to drift.
#
# AND IT REFUSES ON EMPTY. A salvage ref exists to be FOUND BY SOMEONE ELSE, so
# one that cannot name its origin host is half a recovery. Refusing loudly at
# the moment of creation, while the operator is present, beats discovering it
# when someone needs the ref.
_ai="$(dirname "${BASH_SOURCE[0]}")/agent-identity.sh"
HOST="$([ -x "$_ai" ] && "$_ai" node-name 2>/dev/null || true)"
HOST="$(printf '%s' "$HOST" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
if [ -z "$HOST" ]; then
    echo "refused:host-unresolved: scripts/agent-identity.sh node-name returned nothing, so this push would be attributed to no host (1337-3tk6). Nothing pushed." >&2
    exit 2
fi
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
    # 1146-8j7i: a clean tree is not necessarily a SAFE tree. MEASURED
    # (yolanda, 2026-09-13): 823-u5zf finished and gated green at 1d7b29bcc,
    # a trunk merge then reds the gate, and every push after that is refused
    # — the commit sits only on the host, on a tree with nothing dirty to
    # salvage. Clean-and-unpushed is exactly the "finished work nothing
    # protects" state 872-c9nd exists for.
    if git branch -r --contains HEAD 2>/dev/null | grep -q 'origin/'; then
        echo "ok:salvage-not-needed"
        exit 0
    fi

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-salvage.XXXXXX")" || {
        echo "fail:salvage:no-tmpdir"; exit 1
    }
    trap 'rm -rf "$tmp"' EXIT INT TERM

    head_sha="$(git rev-parse HEAD 2>/dev/null)" || { echo "fail:salvage:no-head"; exit 1; }

    # Same plumbing as the dirty-tree case below: local ref FIRST (1103-i7xq —
    # a failed push must still leave a findable copy), then push, with the
    # identical three-state verdict grammar.
    if ! git update-ref "$REF" "$head_sha" 2>"$tmp/urerr"; then
        echo "fail:salvage:update-ref:$(head -1 "$tmp/urerr" 2>/dev/null | tr -d '\n' | cut -c1-80)"
        exit 1
    fi

    if ! git push --quiet origin "${head_sha}:${REF}" 2>"$tmp/perr"; then
        echo "ok:salvaged-local:${REF}:${head_sha}"
        {
            echo "  HEAD IS saved, in this repository, at ${REF}."
            echo "  It has NOT reached origin:"
            echo "    $(head -1 "$tmp/perr" 2>/dev/null | tr -d '\n' | cut -c1-120)"
            echo "  It survives a re-clone ONLY if someone pushes it. When the"
            echo "  credential is working again:"
            echo "    git push origin ${REF}"
            echo "  Report this verdict rather than a plain salvage (1103-i7xq)."
        } >&2
        exit 0
    fi

    echo "ok:salvaged-commits:${REF}:${head_sha}"
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

# -A picks up modifications, deletions and untracked files, and honours
# .gitignore (build caches are not work) — but 1146-8j7i MEASURED `git add -A`
# failing FOR THE WHOLE TREE on one path the substrate could not open (Git for Windows, not the filesystem — WSL git on the same drvfs path stages it:
# `error: open("dangling"): Function not implemented`, exit 128, nothing
# staged — verified locally: a single unreadable path aborts `git add -A`
# before it stages anything else). A single unstageable path must not turn
# "preserve everything else" into "preserve nothing", so paths are staged ONE
# AT A TIME: a path that fails to stage is skipped and named; every other
# path still lands.
#
# The path list comes from the same porcelain query as the clean-tree test,
# in -z form so filenames with spaces or newlines round-trip exactly. A
# rename entry (index status column, i.e. X, is R or C) carries a second
# NUL-terminated field, the origin path, which must also be restaged — it is
# now either gone (a deletion) or a no-op, and `git add -A -- <path>` handles
# both correctly.
paths_to_stage=()
while IFS= read -r -d '' _entry; do
    _x="${_entry:0:1}"
    _path="${_entry:3}"
    paths_to_stage+=("$_path")
    if [ "$_x" = "R" ] || [ "$_x" = "C" ]; then
        IFS= read -r -d '' _origpath || break
        paths_to_stage+=("$_origpath")
    fi
done < <(git status --porcelain=v1 --untracked-files=all -z 2>/dev/null)

skipped=0
for path in ${paths_to_stage[@]+"${paths_to_stage[@]}"}; do
    # TILLANDSIAS_SALVAGE_UNSTAGEABLE_GLOB: test-only seam (1146-8j7i). A
    # dangling symlink stages FINE on ext4 — the Git-for-Windows open()-ENOSYS failure
    # is a substrate quirk this host cannot reproduce — so the `symlink`
    # fixture in test-salvage-net.sh forces one path to be unstageable
    # through this glob instead of weakening what production actually tries.
    # Unset in production; never consulted unless the caller sets it.
    if [ -n "${TILLANDSIAS_SALVAGE_UNSTAGEABLE_GLOB:-}" ] \
        && [[ "$path" == ${TILLANDSIAS_SALVAGE_UNSTAGEABLE_GLOB} ]]; then
        echo "skip:salvage:unstageable:${path}"
        skipped=$((skipped + 1))
        continue
    fi
    if ! git add -A -- "$path" 2>"$tmp/err"; then
        echo "skip:salvage:unstageable:${path}"
        skipped=$((skipped + 1))
        continue
    fi
done

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

# ORDER 1103-i7xq: WRITE THE LOCAL REF FIRST. Until this line the commit went
# straight to origin and the only local ref was the remote-tracking one, so a
# failed push left NO COPY — the object existed unreferenced and unreachable,
# which is not a record anyone can find.
#
# That is the wrong way round for this script's whole purpose. It exists
# because refusing to touch dirt protects it from the agent and not from a
# fresh clone (872-c9nd: four hours of work, the untracked file's name in no
# commit on any branch). The hosts most likely to strand work are the ones
# having a bad time — macbookneo could not push for a full day (1025-a896),
# esmeraldinha's token went 401 mid-session — and on exactly those hosts the
# remedy produced nothing.
#
# A local ref costs one plumbing call, survives a dead credential, and turns
# "no copy" into "a copy that has not left the host yet", which a later cycle
# or an operator can push. It does not touch the worktree: update-ref writes
# refs, not files.
if ! git update-ref "$REF" "$commit" 2>"$tmp/urerr"; then
    echo "fail:salvage:update-ref:$(head -1 "$tmp/urerr" 2>/dev/null | tr -d '\n' | cut -c1-80)"
    exit 1
fi

# THREE STATES, NOT TWO. `fail:salvage:push` used to mean "nothing was saved";
# it now means "saved here, not yet elsewhere", and those need different words
# or a reader treats a local copy as no copy and gives up on it.
if ! git push --quiet origin "${commit}:${REF}" 2>"$tmp/perr"; then
    echo "ok:salvaged-local:${REF}:${commit}"
    {
        echo "  The dirt IS saved, in this repository, at ${REF}."
        echo "  It has NOT reached origin:"
        echo "    $(head -1 "$tmp/perr" 2>/dev/null | tr -d '\n' | cut -c1-120)"
        echo "  It survives a re-clone ONLY if someone pushes it. When the"
        echo "  credential is working again:"
        echo "    git push origin ${REF}"
        echo "  Report this verdict rather than a plain salvage (1103-i7xq)."
        [ "$skipped" -gt 0 ] && echo "  ${skipped} path(s) were skipped as unstageable; see skip:salvage:unstageable lines above."
    } >&2
    exit 0
fi

# 1146-8j7i: the skipped count is a separate stderr line, not appended to the
# verdict — every existing caller derives the ref/sha by splitting ok:salvaged
# on ':', and that grammar stays exact whether or not anything was skipped.
if [ "$skipped" -gt 0 ]; then
    echo "  ${skipped} path(s) could not be staged by this substrate and were skipped; see skip:salvage:unstageable lines above. Salvage proceeded without them." >&2
fi
echo "ok:salvaged:${REF}:${commit}"
