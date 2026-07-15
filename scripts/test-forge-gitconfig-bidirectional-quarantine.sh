#!/usr/bin/env bash
# @trace spec:git-mirror-service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEFAULT_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/../VERSION")"
IMAGE="${TILLANDSIAS_FORGE_IMAGE:-localhost/tillandsias-forge:v${_DEFAULT_VERSION}}"
# ci-full bumps VERSION before its build phase, so the exact-version image
# cannot exist yet on a fresh bump (pre-build chicken-and-egg; 2026-07-15).
# These fixtures test ENTRYPOINT SEMANTICS, not version freshness — fall
# back to the newest available forge image when the exact tag is absent.
if ! podman image exists "$IMAGE"; then
    _NEWEST="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null         | grep -E '^localhost/tillandsias-forge:v[0-9]' | sort -V | tail -1)"
    if [ -n "$_NEWEST" ]; then
        echo "note: $IMAGE absent; testing newest available $_NEWEST" >&2
        IMAGE="$_NEWEST"
    else
        echo "FAIL: no tillandsias-forge image available (need one build first)" >&2
        exit 1
    fi
fi

tmp="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT

upstream="$tmp/upstream.git"
project="$tmp/project"
facade="$tmp/forge-gitdir"

git init --bare --quiet "$upstream"
git init --quiet "$project"
git -C "$project" config user.name Host
git -C "$project" config user.email host@example.test
printf 'host\n' >"$project/tracked.txt"
git -C "$project" add tracked.txt
git -C "$project" commit --quiet -m host
git -C "$project" branch -M main
git -C "$project" remote add origin "file://$upstream"
git -C "$project" push --quiet -u origin main

git -C "$project" config credential.helper host-secret-helper
git -C "$project" config url.ssh://host-only/.insteadOf https://github.com/
git -C "$project" config include.path /host/secret.gitconfig
git -C "$project" config core.hooksPath /host/hooks
cp "$project/.git/config" "$tmp/host-config.before"

mkdir -p "$facade/objects" "$facade/refs" "$facade/logs"
cp "$project/.git/HEAD" "$facade/"
git config --file "$facade/config" core.repositoryformatversion 0
git config --file "$facade/config" core.bare false
git config --file "$facade/config" core.logallrefupdates true
git config --file "$facade/config" gc.auto 0
git config --file "$facade/config" maintenance.auto false
git config --file "$facade/config" remote.origin.url file:///upstream
git config --file "$facade/config" remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
GIT_OBJECT_DIRECTORY="$project/.git/objects" \
    git --git-dir="$facade" read-tree "$(git -C "$project" rev-parse 'HEAD^{tree}')"

podman run --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --userns=keep-id \
    --mount "type=bind,source=$project,target=/workspace" \
    --mount "type=bind,source=$facade,target=/workspace/.git" \
    --mount "type=bind,source=$project/.git/objects,target=/workspace/.git/objects" \
    --mount "type=bind,source=$project/.git/refs,target=/workspace/.git/refs" \
    --mount "type=bind,source=$upstream,target=/upstream" \
    --env GIT_CONFIG_GLOBAL=/dev/null \
    --env GIT_CONFIG_SYSTEM=/dev/null \
    --entrypoint /bin/bash \
    "$IMAGE" -euc '
        cd /workspace
        test -z "$(git config --local --get credential.helper || true)"
        test -z "$(git config --local --get-regexp "^url\..*\.insteadOf$" || true)"
        test -z "$(git config --local --get include.path || true)"
        test -z "$(git config --local --get core.hooksPath || true)"
        git fetch --quiet origin
        git config --local user.x forge-only
        git config --local url.git://forge-only/.insteadOf https://example.test/
        git config user.name Forge
        git config user.email forge@example.test
        printf "forge\n" >>tracked.txt
        git add tracked.txt
        git commit --quiet -m forge
        git push --quiet origin HEAD:refs/heads/main
        git rev-parse HEAD >.forge-head
    '

cmp "$tmp/host-config.before" "$project/.git/config"
! git config --file "$project/.git/config" --get user.x >/dev/null
! git config --file "$project/.git/config" --get-regexp '^url\..*\.insteadOf$' \
    | grep -Fq 'forge-only'
test "$(git config --file "$facade/config" --get user.x)" = forge-only
git config --file "$facade/config" --get-regexp '^url\..*\.insteadOf$' \
    | grep -Fq 'forge-only'

forge_head="$(cat "$project/.forge-head")"
test "$(git -C "$project" rev-parse refs/heads/main)" = "$forge_head"
test "$(git --git-dir="$upstream" rev-parse refs/heads/main)" = "$forge_head"
git -C "$project" cat-file -e "$forge_head^{commit}"
grep -Fq forge "$project/tracked.txt"

echo "PASS: forge gitconfig bidirectional quarantine (order 321)"
