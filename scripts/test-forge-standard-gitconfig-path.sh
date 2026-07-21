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

config="$tmp/gitconfig"
git config --file "$config" safe.directory '/home/forge/src/*'
git config --file "$config" credential.helper ''
git config --file "$config" url.git://tillandsias-git/.insteadOf \
    https://github.com/example/

podman run --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --userns=keep-id \
    --mount "type=bind,source=$config,target=/home/forge/.gitconfig,readonly=true" \
    --entrypoint /bin/bash \
    "$IMAGE" -euc '
        test -z "${GIT_CONFIG_GLOBAL:-}"
        value="$(git config --global --get safe.directory)"
        origin="$(git config --global --show-origin --get safe.directory)"
        test "$value" = "/home/forge/src/*"
        case "$origin" in
            file:/home/forge/.gitconfig*) ;;
            *) printf "FAIL: unexpected global config origin: %s\n" "$origin" >&2; exit 1 ;;
        esac
        redirect="$(git config --global --show-origin --get-regexp "^url\..*\.insteadof$")"
        case "$redirect" in
            "file:/home/forge/.gitconfig"*"https://github.com/example/") ;;
            *) printf "FAIL: unexpected mirror redirect: %s\n" "$redirect" >&2; exit 1 ;;
        esac
        ! git config --global user.name forge-write-must-fail 2>/dev/null
    '

echo "PASS: forge uses the standard read-only global gitconfig path"
