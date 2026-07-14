#!/usr/bin/env bash
# @trace spec:git-mirror-service
set -euo pipefail

IMAGE="${TILLANDSIAS_FORGE_IMAGE:-localhost/tillandsias-forge:latest}"
podman image exists "$IMAGE" || {
    echo "FAIL: required forge image is absent: $IMAGE" >&2
    exit 1
}

tmp="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT

config="$tmp/gitconfig"
git config --file "$config" safe.directory '/home/forge/src/*'
git config --file "$config" credential.helper ''

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
        ! git config --global user.name forge-write-must-fail 2>/dev/null
    '

echo "PASS: forge uses the standard read-only global gitconfig path"
