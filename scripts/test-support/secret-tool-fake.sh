#!/usr/bin/env bash
# Stub `secret-tool` for tests. Stores secrets in a file under
# $LITMUS_SECRET_TOOL_STORE so tests can verify writes without touching
# the real keyring. Mimics the subset of secret-tool semantics that
# scripts/generate-repo-key.sh actually exercises:
#   secret-tool store --label <label> service <s> account <a>      (reads stdin)
#   secret-tool lookup service <s> account <a>                     (prints stdout)
#
# @trace spec:gh-auth-script

set -euo pipefail

: "${LITMUS_SECRET_TOOL_STORE:?LITMUS_SECRET_TOOL_STORE must be set}"
mkdir -p "$LITMUS_SECRET_TOOL_STORE"

# parse_attrs <args...>
# Returns "service|account" joined by '|'.
parse_attrs() {
    local service="" account=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            service)  shift; service="$1"; shift ;;
            account)  shift; account="$1"; shift ;;
            *)        shift ;;
        esac
    done
    printf '%s|%s' "$service" "$account"
}

slugify() {
    printf '%s' "$1" | tr '/:' '__'
}

cmd="${1:-}"; shift || true

case "$cmd" in
    store)
        # Drop --label <text>
        while [[ "${1:-}" == --* ]]; do
            case "$1" in
                --label) shift; shift ;;
                *)       shift ;;
            esac
        done
        key=$(parse_attrs "$@")
        slug=$(slugify "$key")
        # Read secret from stdin
        cat >"$LITMUS_SECRET_TOOL_STORE/$slug"
        ;;
    lookup)
        key=$(parse_attrs "$@")
        slug=$(slugify "$key")
        file="$LITMUS_SECRET_TOOL_STORE/$slug"
        if [[ -f "$file" ]]; then
            cat "$file"
        else
            exit 1
        fi
        ;;
    *)
        printf 'fake secret-tool: unsupported command %s\n' "$cmd" >&2
        exit 2
        ;;
esac
