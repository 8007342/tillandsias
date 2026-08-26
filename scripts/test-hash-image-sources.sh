#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HASHER="$ROOT/scripts/hash-image-sources.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hash-image-sources.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/repo"
mkdir -p "$repo/images/default" "$repo/skills/meta" \
    "$repo/cheatsheets" "$repo/cheatsheet-sources"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'FROM scratch\n' >"$repo/images/default/Containerfile"
printf 'safe contract v1\n' >"$repo/skills/meta/SKILL.md"
printf 'alternate contract\n' >"$repo/skills/meta/alternate.md"
ln -s SKILL.md "$repo/skills/meta/current"
printf 'cheat\n' >"$repo/cheatsheets/test.md"
printf 'source\n' >"$repo/cheatsheet-sources/test.md"
printf '*.tmp\n' >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm baseline

before="$($HASHER forge "$repo/images/default" "$repo")"
grep -Fq 'layer-policy:squash-new' "$HASHER" || {
    echo "FAIL: squash-new policy is absent from the shell image cache key" >&2
    exit 1
}
git clone -q "$repo" "$WORK/clone"
clone_hash="$($HASHER forge "$WORK/clone/images/default" "$WORK/clone")"
[[ "$before" == "$clone_hash" ]] || {
    echo "FAIL: forge hash depends on checkout location" >&2
    exit 1
}
# ORDER 776-cm74 — STAGE the mode, do not just chmod the worktree.
#
# The hasher takes tracked entries' mode and content from `git ls-files -s`,
# i.e. from the INDEX, so an unstaged `chmod +x` correctly does NOT move the
# cache key: the commit's content has not changed. Testing through the index
# is not a workaround, it is the truer test — and it is PORTABLE, which the
# worktree form was not. `git update-index --chmod=+x` works identically on a
# host with `core.fileMode=false`, so this scenario needs no platform gate and
# no skip. The packet's exit criterion asked for a `core.fileMode=true` gate
# with a loud skip elsewhere; index-based hashing removes the need for one,
# which is a better outcome than the criterion asked for and is recorded as
# such rather than silently substituted.
chmod +x "$repo/skills/meta/SKILL.md"
git -C "$repo" update-index --chmod=+x skills/meta/SKILL.md
mode_hash="$($HASHER forge "$repo/images/default" "$repo")"
[[ "$before" != "$mode_hash" ]] || {
    echo "FAIL: executable-bit change did not invalidate forge hash" >&2
    exit 1
}
chmod -x "$repo/skills/meta/SKILL.md"
rm "$repo/skills/meta/current"
ln -s alternate.md "$repo/skills/meta/current"
link_hash="$($HASHER forge "$repo/images/default" "$repo")"
[[ "$before" != "$link_hash" ]] || {
    echo "FAIL: symlink-target change did not invalidate forge hash" >&2
    exit 1
}
rm "$repo/skills/meta/current"
ln -s SKILL.md "$repo/skills/meta/current"
printf 'safe contract v2\n' >"$repo/skills/meta/SKILL.md"
after="$($HASHER forge "$repo/images/default" "$repo")"
[[ "$before" != "$after" ]] || {
    echo "FAIL: canonical skill change did not invalidate forge hash" >&2
    exit 1
}

printf 'untracked skill\n' >"$repo/skills/meta/untracked.md"
if "$HASHER" forge "$repo/images/default" "$repo" >/dev/null 2>&1; then
    echo "FAIL: untracked canonical skill did not fail image hashing" >&2
    exit 1
fi
rm "$repo/skills/meta/untracked.md"
printf 'ignored skill\n' >"$repo/skills/meta/ignored.tmp"
if "$HASHER" forge "$repo/images/default" "$repo" >/dev/null 2>&1; then
    echo "FAIL: ignored canonical skill did not fail image hashing" >&2
    exit 1
fi

# ── ORDER 776-cm74: THE INVARIANCE THE PACKET EXISTS FOR ──────────────────────
#
# This is the scenario the fixture was missing, and without it the change above
# is untested: the hash must not move when the WORKING TREE differs from the
# index in ways git normalizes away. `core.autocrlf=true` on Windows produces
# exactly that state — CRLF in the worktree, LF in the blob — so two clones of
# the SAME commit hashed differently and the cross-location comparison at the
# top of this file could not be truthful there.
#
# Simulated portably by rewriting a tracked file's worktree bytes to CRLF and
# NOT staging them, which is byte-for-byte the state an autocrlf checkout is in.
rm -f "$repo/skills/meta/ignored.tmp"
crlf_before="$("$HASHER" forge "$repo/images/default" "$repo")"
tracked_file="$repo/images/default/Containerfile"
[[ -f "$tracked_file" ]] || tracked_file="$(git -C "$repo" ls-files -- images/default | head -1)"
[[ -n "$tracked_file" ]] && tracked_file="$repo/${tracked_file#"$repo/"}"
if [[ -f "$tracked_file" ]]; then
    sed -i 's/$/\r/' "$tracked_file"
    crlf_after="$("$HASHER" forge "$repo/images/default" "$repo")"
    git -C "$repo" checkout -- "${tracked_file#"$repo/"}"
    [[ "$crlf_before" == "$crlf_after" ]] || {
        echo "FAIL: a CRLF working tree moved the hash — it is still hashing worktree bytes, not git-normalized content" >&2
        exit 1
    }
    # NEGATIVE CONTROL: a change git does NOT normalize away must still move it,
    # or the arm above would pass on a hasher that ignores content entirely.
    printf 'genuinely new line\n' >>"$tracked_file"
    git -C "$repo" add "${tracked_file#"$repo/"}"
    real_after="$("$HASHER" forge "$repo/images/default" "$repo")"
    [[ "$crlf_before" != "$real_after" ]] || {
        echo "FAIL: a real staged content change did not move the hash — the CRLF arm proves nothing" >&2
        exit 1
    }
else
    echo "SKIP: no tracked file under images/default to test CRLF invariance" >&2
fi

echo "PASS: canonical skills participate in forge image cache key"
