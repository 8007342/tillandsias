#!/bin/sh
# @trace spec:tillandsias-vault, spec:git-mirror-service, spec:secrets-management
#
# Minimal Vault client shim baked into the default forge image. Wraps the
# curl + jq pattern forge helpers use to read and write provider credentials
# without pulling in the upstream `vault` CLI binary (~80MB).
#
# Lifecycle:
#   * VAULT_ADDR        — e.g. https://vault:8200 (set by the launcher)
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
umask 077

VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
if [ -n "${VAULT_CACERT:-}" ]; then
    : # Explicit Vault-specific selection wins.
elif [ -n "${CURL_CA_BUNDLE:-}" ]; then
    VAULT_CACERT="$CURL_CA_BUNDLE"
elif [ -r "${TILLANDSIAS_VAULT_LOGIN_CACERT:-/etc/tillandsias/ca.crt}" ]; then
    # Provider-login containers mount the intermediate here.
    VAULT_CACERT="${TILLANDSIAS_VAULT_LOGIN_CACERT:-/etc/tillandsias/ca.crt}"
else
    # Resident forge entrypoints compose vendor + runtime roots here.
    VAULT_CACERT="${TILLANDSIAS_VAULT_RUNTIME_CACERT:-/run/tillandsias/ca-bundle.crt}"
fi

require_cacert() {
    if [ ! -r "$VAULT_CACERT" ]; then
        echo "vault-cli: CA bundle not readable at $VAULT_CACERT" >&2
        echo "vault-cli: refusing to talk to $VAULT_ADDR without TLS verification." >&2
        echo "vault-cli: set VAULT_CACERT/CURL_CA_BUNDLE or mount the intermediate CA." >&2
        exit 2
    fi
}

usage() {
    cat <<EOF >&2
Usage: vault-cli read [-field=<key>] <path>
       vault-cli write <path> <field>=<value> [<field>=<value> ...]
       vault-cli write-stdin <path> <field>
       vault-cli health

Examples:
  vault-cli read -field=token secret/github/token
  vault-cli read secret/github/token
  vault-cli write secret/github/token token=ghp_example
  printf '%s' opaque-value | vault-cli write-stdin secret/provider/oauth credentials_b64
EOF
}

read_token() {
    if [ ! -r "$VAULT_TOKEN_FILE" ]; then
        echo "vault-cli: no Vault token at $VAULT_TOKEN_FILE" >&2
        exit 1
    fi
    cat "$VAULT_TOKEN_FILE"
}

# Keep the Vault token out of curl's argv. curl reads the header from a
# mode-0600 temporary file, and callers provide request bodies on stdin.
curl_with_token() {
    token="$(read_token)"
    header_file="$(mktemp /tmp/tillandsias-vault-header.XXXXXX)" || {
        echo "vault-cli: cannot create tmpfs token-header file" >&2
        return 2
    }
    if ! printf 'X-Vault-Token: %s\n' "$token" > "$header_file"; then
        rm -f "$header_file"
        echo "vault-cli: cannot write tmpfs token-header file" >&2
        return 2
    fi
    token=""

    curl_status=0
    curl --cacert "$VAULT_CACERT" -fsS --header "@$header_file" "$@" \
        || curl_status=$?

    header_size="$(wc -c < "$header_file" 2>/dev/null || printf '0')"
    if [ "$header_size" -gt 0 ] 2>/dev/null; then
        dd if=/dev/zero of="$header_file" bs=1 count="$header_size" \
            conv=notrunc 2>/dev/null || true
    fi
    rm -f "$header_file"
    return "$curl_status"
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
    if ! body="$(curl_with_token "$VAULT_ADDR/v1/$kv_path" 2>&1)"; then
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

write_json() {
    path="$1"
    json_body="$2"
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
    if ! response="$(printf '%s' "$json_body" \
        | curl_with_token --data-binary @- "$VAULT_ADDR/v1/$kv_path" 2>&1)"; then
        echo "vault-cli: HTTP error writing $kv_path: $response" >&2
        exit 2
    fi
    printf '%s' "$response" | jq -r '.data // empty'
}

cmd_write() {
    if [ $# -lt 2 ]; then
        usage
        exit 4
    fi
    path="$1"
    shift
    # Build JSON data object from key=value arguments using jq
    json_body='{"data": {}}'
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        json_body="$(printf '%s' "$json_body" | jq --arg k "$key" --arg v "$value" '.data[$k] = $v')"
    done
    write_json "$path" "$json_body"
}

cmd_write_stdin() {
    if [ $# -ne 2 ]; then
        usage
        exit 4
    fi
    path="$1"
    field="$2"
    # Read the secret value from stdin so it never appears in process argv or
    # an environment variable. jq consumes the stream and returns only the
    # Vault KV-v2 request envelope.
    json_body="$(jq -Rs --arg k "$field" '{data: {($k): .}}')"
    write_json "$path" "$json_body"
}

cmd_health() {
    curl --cacert "$VAULT_CACERT" -fsS "$VAULT_ADDR/v1/sys/health?sealedcode=200&uninitcode=200&standbyok=true" \
        || { echo "vault-cli: health probe failed" >&2; exit 2; }
}

case "${1:-}" in
    read|write|write-stdin|health) require_cacert ;;
esac

case "${1:-}" in
    read) shift; cmd_read "$@" ;;
    write) shift; cmd_write "$@" ;;
    write-stdin) shift; cmd_write_stdin "$@" ;;
    health) cmd_health ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) echo "vault-cli: unknown subcommand: $1" >&2; usage; exit 4 ;;
esac
