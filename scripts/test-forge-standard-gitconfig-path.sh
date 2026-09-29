#!/usr/bin/env bash
# @trace spec:git-mirror-service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ORDER 800-ivkg: SAY WHERE THE TIME WENT, AND WHICH ENVIRONMENT FAILED.
# This step once went red at its 30 s litmus budget on a green tree while the
# host ran at load 12 with `podman info` answering in 53 s, and nothing said
# so. The fixture now times its own phases, bounds the container run BELOW the
# step budget, and on that bound fails by name with the host's load and a timed
# `podman info`, so a slow host reads as SLOW and never as a config regression.
# Milliseconds, digit-validated like build.sh _now_ms: BSD date passes %N
# through literally, so a non-digit reading degrades to whole seconds.
_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null || true)" # gnu-date: ok (digit-validated below; degrades to seconds)
    case "$t" in
        ''|*[!0-9]*)
            t="$(date +%s 2>/dev/null || true)"
            case "$t" in
                ''|*[!0-9]*) t=0 ;;
                *) t=$((t * 1000)) ;;
            esac
            ;;
    esac
    printf '%s\n' "$t"
}
_T0="$(_ms)"
CONTAINER_BOUND_SECS="${TILLANDSIAS_GITCONFIG_FIXTURE_BOUND_SECS:-25}"
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

_T_IMAGE="$(_ms)"
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

_T_RUN0="$(_ms)"
_run_rc=0
timeout "$CONTAINER_BOUND_SECS" podman run --rm \
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
    ' || _run_rc=$?
_T_RUN1="$(_ms)"
_load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
echo "timing: image_lookup_ms=$((_T_IMAGE - _T0)) container_ms=$((_T_RUN1 - _T_RUN0)) loadavg=[$_load]"
if [ "$_run_rc" -eq 124 ]; then
    _pi0="$(_ms)"; timeout 60 podman info >/dev/null 2>&1; _pi_rc=$?; _pi1="$(_ms)"
    echo "SLOW: the forge container did not finish within ${CONTAINER_BOUND_SECS}s — a HOST condition, not a gitconfig regression: loadavg=[$_load], podman info took $((_pi1 - _pi0))ms (rc=$_pi_rc). Re-run on a quieter host before reading this as a defect (800-ivkg)." >&2
    exit 124
fi
[ "$_run_rc" -eq 0 ] || exit "$_run_rc"

echo "PASS: forge uses the standard read-only global gitconfig path"
