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
git clone -q "$repo" "$WORK/clone"
clone_hash="$($HASHER forge "$WORK/clone/images/default" "$WORK/clone")"
[[ "$before" == "$clone_hash" ]] || {
    echo "FAIL: forge hash depends on checkout location" >&2
    exit 1
}
chmod +x "$repo/skills/meta/SKILL.md"
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

echo "PASS: canonical skills participate in forge image cache key"
