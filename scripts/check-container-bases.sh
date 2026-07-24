#!/usr/bin/env bash
# check-container-bases.sh — enforce container base-image policy.
#
# The project intentionally mixes Fedora and Alpine:
#   - Fedora/glibc for agent, browser, inference, and SELinux-sensitive roles.
#   - Alpine/musl only for small appliance roles with narrow runtime behavior.
#
# @trace spec:default-image, spec:inference-container, spec:browser-isolation-core, spec:browser-isolation-framework, spec:proxy-container, spec:git-mirror-service, spec:web-image, spec:subdomain-routing-via-reverse-proxy

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0
checked=0

fail() {
    echo "ERROR: $*" >&2
    errors=$((errors + 1))
}

expect_base() {
    local file="$1"
    shift
    local from_line line image allowed match

    if [[ ! -f "$ROOT/$file" ]]; then
        fail "$file is missing"
        return
    fi

    from_line="$(grep -E '^[[:space:]]*FROM[[:space:]]+' "$ROOT/$file" || true)"
    if [[ -z "$from_line" ]]; then
        fail "$file has no FROM line"
        return
    fi

    checked=$((checked + 1))
    while IFS= read -r line; do
        image="$(awk '{ print $2 }' <<< "$line")"
        match=false

        if [[ "$image" == *:latest || "$image" == latest ]]; then
            fail "$file uses unpinned latest tag: $image"
        fi

        for allowed in "$@"; do
            if [[ "$image" == "$allowed" ]]; then
                match=true
                break
            fi
        done

        if [[ "$match" != true ]]; then
            fail "$file uses '$image'; expected one of: $*"
        fi
    done <<< "$from_line"
}

expect_base "images/default/Containerfile" "registry.fedoraproject.org/fedora-minimal:44" '${BASE_IMAGE}'
expect_base "images/default/Containerfile.base" "registry.fedoraproject.org/fedora-minimal:44"
expect_base "images/inference/Containerfile" "registry.fedoraproject.org/fedora-minimal:44"
expect_base "images/chromium/Containerfile.core" "registry.fedoraproject.org/fedora-minimal:44"
expect_base "images/chromium/Containerfile.framework" 'tillandsias-chromium-core:${CHROMIUM_CORE_TAG}' '${CHROMIUM_CORE_IMAGE}'

expect_base "images/proxy/Containerfile" "docker.io/library/alpine:3.20"
expect_base "images/git/Containerfile" "docker.io/library/alpine:3.20" "docker.io/hashicorp/vault:1.18"
expect_base "images/web/Containerfile" "docker.io/library/alpine:3.20"
expect_base "images/router/Containerfile" "docker.io/library/caddy:2-alpine"

latest_hits="$(
    # test-running-image-freshness.sh excluded: fixture must name the freshest local build
    grep -RInE 'tillandsias-[a-z0-9_-]+:latest|docker\.io/library/[a-z0-9_-]+:latest|alpine:latest|nixos/nix:latest' \
        --exclude='check-container-bases.sh' \
        --exclude='build-image.sh' \
        --exclude='test-running-image-freshness.sh' \
        "$ROOT/scripts" \
        "$ROOT/images" \
        "$ROOT/docs/cheatsheets" \
        "$ROOT/openspec/specs" \
        "$ROOT/crates/tillandsias-core/src/container_profile.rs" \
        "$ROOT/crates/tillandsias-podman/src/client.rs" \
        2>/dev/null || true
)"
if [[ -n "$latest_hits" ]]; then
    fail "runtime/build docs or scripts contain mutable latest tags:"
    while IFS= read -r hit; do
        [[ -n "$hit" ]] && echo "  $hit" >&2
    done <<< "$latest_hits"
fi

if [[ "$errors" -gt 0 ]]; then
    echo "container-base-policy: $errors error(s), $checked Containerfile(s) checked" >&2
    exit 1
fi

echo "container-base-policy: ok ($checked Containerfile(s) checked)"
