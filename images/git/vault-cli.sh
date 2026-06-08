#!/bin/sh
# @trace spec:tillandsias-vault, spec:git-mirror-service, spec:secrets-management
#
# Minimal Vault client shim baked into the git-mirror image. Wraps the
# curl + jq pattern the post-receive hook uses to read GitHub tokens (and
# any other secret the git mirror is policy-permitted to see) without
# pulling in the upstream `vault` CLI binary (~80MB).
#
# Lifecycle:
#   * VAULT_ADDR        — e.g. http://vault:8200 (set by the launcher)
#   * /run/secrets/vault-token — short-lived AppRole token (mounted by
#     podman --secret <name>,target=vault-token; the launcher mints it via
#     `vault-client::issue_approle_token("git-mirror")`).
#
# Usage:
#   vault-cli read -field=token secret/github/token
#
# Exit codes: 0 success; 1 missing token mount; 2 HTTP/curl failure;
# 3 malformed Vault response; 4 unknown subcommand.

set -eu

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"

usage() {
    cat <<EOF >&2
Usage: vault-cli read [-field=<key>] <path>
       vault-cli write <path> <field>=<value> [<field>=<value> ...]
       vault-cli health

Examples:
  vault-cli read -field=token secret/github/token
  vault-cli read secret/github/token
  vault-cli write secret/github/token token=ghp_example
EOF
}

read_token() {
    if [ ! -r "$VAULT_TOKEN_FILE" ]; then
        echo "vault-cli: no Vault token at $VAULT_TOKEN_FILE" >&2
        exit 1
    fi
    cat "$VAULT_TOKEN_FILE"
}

cmd_read() {
    field=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -field=*) field="${1#-field=}"; shift ;;
            --field=*) field="${1#--field=}"; shift ;;
            -field|--field)
                shift
                field="$1"
                shift
                ;;
            --) shift; break ;;
            -*) echo "vault-cli: unknown read flag $1" >&2; usage; exit 4 ;;
            *) break ;;
        esac
    done
    if [ $# -ne 1 ]; then
        usage
        exit 4
    fi
    path="$1"
    # Normalise the KV-v2 mount: secret/foo -> secret/data/foo. If the
    # caller already supplied secret/data/... pass through.
    case "$path" in
        */data/*) kv_path="$path" ;;
        */data) kv_path="$path" ;;
        */)     kv_path="${path%/}" ;;
        *)
            mount="${path%%/*}"
            rest="${path#*/}"
            if [ "$rest" = "$path" ]; then
                kv_path="$mount"
            else
                kv_path="$mount/data/$rest"
            fi
            ;;
    esac
    token="$(read_token)"
    if ! body="$(curl -fsS -H "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/$kv_path" 2>&1)"; then
        echo "vault-cli: HTTP error reading $kv_path: $body" >&2
        exit 2
    fi
    if [ -n "$field" ]; then
        value="$(printf '%s' "$body" | jq -r ".data.data.${field} // empty")"
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            echo "vault-cli: field '$field' missing or null at $kv_path" >&2
            exit 3
        fi
        printf '%s' "$value"
    else
        # Whole envelope; caller can pipe through jq.
        printf '%s' "$body"
    fi
}

cmd_write() {
    if [ $# -lt 2 ]; then
        usage
        exit 4
    fi
    path="$1"
    shift
    # Build JSON data object from key=value arguments
    data=""
    sep=""
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        # JSON-encode the value: escape backslash, quote, newline, tab
        encoded="$(printf '%s' "$value" | sed 's/[\"\\/]/\\&/g; s/
/\\n/g; s/	/\\t/g')"
        data="${data}${sep}\"${key}\": \"${encoded}\""
        sep=", "
    done
    # Normalise the KV-v2 mount (same as cmd_read)
    case "$path" in
        */data/*) kv_path="$path" ;;
        */data) kv_path="$path" ;;
        */)     kv_path="${path%/}" ;;
        *)
            mount="${path%%/*}"
            rest="${path#*/}"
            if [ "$rest" = "$path" ]; then
                kv_path="$mount"
            else
                kv_path="$mount/data/$rest"
            fi
            ;;
    esac
    token="$(read_token)"
    json_body="{\"data\": {$data}}"
    if ! response="$(curl -fsS -H "X-Vault-Token: $token" \
        -d "$json_body" "$VAULT_ADDR/v1/$kv_path" 2>&1)"; then
        echo "vault-cli: HTTP error writing $kv_path: $response" >&2
        exit 2
    fi
    printf '%s' "$response" | jq -r '.data // empty'
}

cmd_health() {
    curl -fsS "$VAULT_ADDR/v1/sys/health?sealedcode=200&uninitcode=200&standbyok=true" \
        || { echo "vault-cli: health probe failed" >&2; exit 2; }
}

case "${1:-}" in
    read) shift; cmd_read "$@" ;;
    write) shift; cmd_write "$@" ;;
    health) cmd_health ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) echo "vault-cli: unknown subcommand: $1" >&2; usage; exit 4 ;;
esac
