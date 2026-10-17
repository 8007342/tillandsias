#!/usr/bin/env bash
# @trace order:667-kfyn
#
# wsl2-src-mirror.sh — keep a distro-native copy of a /mnt/c checkout, so the
# tillandsias-build WSL2 distro builds from ext4 instead of reading every
# source file across 9p onto NTFS. Runs INSIDE the build distro; called by
# scripts/with-wsl2-builder.sh when TILLANDSIAS_WSL2_SRC_MIRROR=1.
#
#   wsl2-src-mirror.sh sync <src> <mirror> <want-digest>
#       Make <mirror> byte-identical to the <src> worktree, then prove it:
#       scripts/gate-stamp.sh compute in the mirror must equal <want-digest>,
#       which the caller computed on the source side. That digest is the one
#       the pre-push hook checks (content + mode of every tracked and
#       untracked file), so "the mirror matches" means exactly "a stamp the
#       mirror writes is a stamp the source accepts". A mismatch refuses, and
#       nothing is built from a wrong tree.
#   wsl2-src-mirror.sh writeback <mirror> <src>
#       Copy the gate's own records (.git/tillandsias-*, not locks) that the
#       run wrote in the mirror back to the source's .git, where the hooks
#       read them. Same files an in-tree run would have left there.
#
# What is copied:
#   - commits and refs: git fetch from the source (one pack, 9p's good case);
#     the mirror checks out the source's HEAD on the same branch name;
#   - the dirty worktree: `git diff --binary HEAD` applied in the mirror;
#   - untracked files, and IGNORED files outside the build-output dirs in
#     IGNORED_SKIP (the build reads some ignored inputs, e.g. the guest
#     binaries the Windows tray embeds), copied only when size or mtime moved.
#
# Verdicts (last line):
#   ok:wsl2-src-mirror:synced:<mirror>:<digest>                  exit 0
#   ok:wsl2-src-mirror:writeback:<n>                             exit 0
#   refused:wsl2-src-mirror:fidelity:<want>:<got>                exit 1
#   could-not-run:wsl2-src-mirror:<why>                          exit 3
set -euo pipefail

# Build outputs and per-host scratch: never inputs to a check, often huge.
IGNORED_SKIP='^(target|target-guest|target-musl|release-artifacts|\.nix-output|result|\.cache|\.claude|\.tillandsias/fixture-scratch)(/|$)'

die3() { echo "could-not-run:wsl2-src-mirror:$1"; exit 3; }

# copy_list <src> <mirror>: NUL-separated relative paths on stdin; copy each
# file whose size or mtime differs (cp -p keeps mtime, so an unchanged file is
# skipped on the next run without reading its bytes across 9p).
copy_list() {
    local src="$1" mirror="$2" rel s m n=0
    while IFS= read -r -d '' rel; do
        [ -e "$src/$rel" ] || [ -L "$src/$rel" ] || continue
        if [ -L "$src/$rel" ] || [ ! -e "$mirror/$rel" ] \
            || [ "$(stat -c '%s %Y' "$src/$rel")" != "$(stat -c '%s %Y' "$mirror/$rel" 2>/dev/null)" ]; then
            mkdir -p "$mirror/$(dirname "$rel")"
            rm -rf "${mirror:?}/$rel"
            cp -pP "$src/$rel" "$mirror/$rel"
            n=$((n + 1))
        fi
    done
    echo "$n"
}

# expand_dirs <src>: NUL-separated entries on stdin; a directory entry (trailing
# /) becomes the files and symlinks under it, relative to <src>.
expand_dirs() {
    local src="$1" e
    while IFS= read -r -d '' e; do
        case "$e" in
            */) (cd "$src" && find "${e%/}" \( -type f -o -type l \) -print0) ;;
            *) printf '%s\0' "$e" ;;
        esac
    done
}

sync_mirror() {
    local src="$1" mirror="$2" want="$3"
    [ -d "$src/.git" ] || [ -f "$src/.git" ] || die3 "source-is-not-a-checkout:$src"
    [ -n "$want" ] || die3 "no-source-digest"
    if [ ! -d "$mirror/.git" ]; then
        mkdir -p "$(dirname "$mirror")"
        # World-readable: gate fixtures source repo files as an unprivileged
        # user (920-tqhs runs `runuser -u nobody`), as they can from /mnt/c.
        chmod 0755 "$(dirname "$mirror")"
        echo "[wsl2-src-mirror] first run: cloning $src into $mirror (one-time pack copy)" >&2
        git clone -q --no-checkout "$src" "$mirror"
    fi
    cd "$mirror"
    # The checkout's own core.symlinks / core.fileMode, so the mirror holds
    # the same KIND of entry the source does: a Windows checkout has
    # core.symlinks=false and keeps tracked symlinks as plain files, and an
    # in-tree build reads them that way. Changing either value re-checks-out
    # every entry, because git rewrites only paths it thinks changed.
    local k v recheckout=0
    for k in core.symlinks core.fileMode; do
        v="$(git -C "$src" config --get "$k" || echo true)"
        if [ "$(git config --get "$k" || echo unset)" != "$v" ]; then
            git config "$k" "$v"
            recheckout=1
        fi
    done
    if [ "$recheckout" = 1 ] && git rev-parse -q --verify HEAD >/dev/null; then
        git ls-files -z | (xargs -0 rm -f -- 2>/dev/null || true)
    fi
    local url
    url="$(git -C "$src" config --get remote.origin.url || true)"
    [ -z "$url" ] || git remote set-url origin "$url"
    git fetch -q --no-tags --update-head-ok "$src" \
        '+refs/heads/*:refs/heads/*' '+refs/remotes/origin/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
    local head branch
    head="$(git -C "$src" rev-parse HEAD)"
    branch="$(git -C "$src" symbolic-ref -q --short HEAD || true)"
    if [ -n "$branch" ]; then git checkout -q -f -B "$branch" "$head"; else git checkout -q -f --detach "$head"; fi
    git reset -q --hard "$head"
    # Untracked files of the last run go; ignored files stay, so the ignored
    # inputs below are re-copied only when they changed.
    git clean -q -ffd
    # Tracked changes, deletions and mode changes the source's git can see.
    local patch="$mirror/.git/tillandsias-mirror-dirty.patch"
    git -C "$src" diff --binary HEAD > "$patch"
    [ ! -s "$patch" ] || git apply --binary --whitespace=nowarn "$patch"
    local untracked ignored
    untracked="$(git -C "$src" ls-files -z --others --exclude-standard | copy_list "$src" "$mirror")"
    # --directory stops at a fully ignored directory (one entry for target/,
    # whose walk across 9p took 44 s on yolanda); the directories that survive
    # IGNORED_SKIP are expanded here, inside the mirror's own process.
    ignored="$(git -C "$src" ls-files -z --others --ignored --exclude-standard --directory \
        | { grep -zvE "$IGNORED_SKIP" || true; } | expand_dirs "$src" | copy_list "$src" "$mirror")"
    echo "[wsl2-src-mirror] copied untracked=$untracked ignored=$ignored" >&2
    local got
    got="$(bash scripts/gate-stamp.sh compute)" || die3 "mirror-digest-failed"
    if [ "$got" != "$want" ]; then
        echo "why: the mirror is not byte-identical to the checkout, so a build here would validate a tree you do not have"
        echo "remedy: re-run; if it repeats, run with TILLANDSIAS_WSL2_SRC_MIRROR unset to build in-tree, and report the mismatch on 667-kfyn"
        echo "refused:wsl2-src-mirror:fidelity:$want:$got"
        exit 1
    fi
    : > "$mirror/.git/tillandsias-mirror-synced"
    echo "ok:wsl2-src-mirror:synced:$mirror:$got"
}

writeback() {
    local mirror="$1" src="$2" f n=0 srcgit
    srcgit="$(git -C "$src" rev-parse --absolute-git-dir)" || die3 "no-source-git-dir"
    [ -e "$mirror/.git/tillandsias-mirror-synced" ] || die3 "mirror-never-synced"
    for f in "$mirror"/.git/tillandsias-*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            tillandsias-mirror-synced|*lock*) continue ;;
        esac
        [ "$f" -nt "$mirror/.git/tillandsias-mirror-synced" ] || continue
        cp -p "$f" "$srcgit/$(basename "$f")"
        n=$((n + 1))
    done
    echo "ok:wsl2-src-mirror:writeback:$n"
}

case "${1:-}" in
    sync) [ $# -eq 4 ] || die3 "usage:sync-src-mirror-digest"; sync_mirror "$2" "$3" "$4" ;;
    writeback) [ $# -eq 3 ] || die3 "usage:writeback-mirror-src"; writeback "$2" "$3" ;;
    *) die3 "usage:sync|writeback" ;;
esac
