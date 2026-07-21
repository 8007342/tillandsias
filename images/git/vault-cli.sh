#!/bin/sh
# @trace spec:tillandsias-vault, spec:git-mirror-service, spec:secrets-management
#
# Minimal Vault client shim baked into the git-mirror image. Wraps the
# curl + jq pattern the post-receive hook uses to read GitHub tokens (and
# any other secret the git mirror is policy-permitted to see) without
# pulling in the upstream `vault` CLI binary (~80MB).
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

VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"

# TLS verification against the Tillandsias intermediate CA (order 426).
#
# These calls used `curl -k` at six sites, which disabled verification on the
# very requests that carry the Vault token — a MITM anywhere on the enclave
# network could have harvested it. That predated a commit explicitly requiring
# CA-authenticated HTTPS, and was unnecessary the whole time: the launcher
# already bind-mounts the intermediate CA at /etc/tillandsias/ca.crt and sets
# CURL_CA_BUNDLE to it whenever the Vault token secret is attached, which is
# exactly when this shim runs.
#
# Verified empirically against the live Vault 1.18.5 listener: with --cacert the
# health endpoint returns 200, and WITHOUT any CA it fails "curl failed to
# verify the legitimacy of the server" — so verification is genuinely happening
# rather than being silently skipped.
#
# We pass --cacert explicitly rather than relying on CURL_CA_BUNDLE being
# exported, and we fail LOUD when the bundle is missing instead of degrading to
# -k. A silent fall back to unverified TLS is the failure class this repo keeps
# getting bitten by: it would keep working, look healthy, and quietly drop the
# security property.
VAULT_CACERT="${VAULT_CACERT:-${CURL_CA_BUNDLE:-/etc/tillandsias/ca.crt}}"

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
       vault-cli renew-self [<increment-seconds>]
       vault-cli lookup-self [-field=<key>]
       vault-cli health

Examples:
  vault-cli read -field=token secret/github/token
  vault-cli read secret/github/token
  vault-cli write secret/github/token token=ghp_example
  printf '%s' opaque-value | vault-cli write-stdin secret/provider/oauth credentials_b64
  vault-cli renew-self 3600          # extend this token's lease (approle TTL heartbeat)
  vault-cli lookup-self -field=ttl   # remaining TTL in seconds; exit 2 if expired/invalid
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
    if ! body="$(curl --cacert "$VAULT_CACERT" -fsS -H "X-Vault-Token: $token" \
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
    token="$(read_token)"
    if ! response="$(curl --cacert "$VAULT_CACERT" -fsS -H "X-Vault-Token: $token" \
        -d "$json_body" "$VAULT_ADDR/v1/$kv_path" 2>&1)"; then
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

# @trace spec:tillandsias-vault, spec:git-mirror-service
# Renew the mounted AppRole token against its own lease (token-auth endpoint,
# NOT KV-v2 — no secret/data path normalisation). The git-mirror's approle
# lease has a 1h default TTL and a 24h max TTL; a periodic renew-self keeps the
# mirror's Vault access alive across a long forge session so the relay can read
# the GitHub token for every push, not just the first hour. A renew on an
# already-expired token 403s (exit 2); the caller treats that as "must re-mint"
# (relaunch the forge) rather than a renewable heartbeat.
cmd_renew_self() {
    increment="${1:-}"
    body=""
    if [ -n "$increment" ]; then
        body="{\"increment\": \"${increment}s\"}"
    fi
    token="$(read_token)"
    if [ -n "$body" ]; then
        if ! response="$(curl --cacert "$VAULT_CACERT" -fsS -H "X-Vault-Token: $token" \
            -d "$body" "$VAULT_ADDR/v1/auth/token/renew-self" 2>&1)"; then
            echo "vault-cli: HTTP error renewing token: $response" >&2
            exit 2
        fi
    else
        if ! response="$(curl --cacert "$VAULT_CACERT" -fsS -H "X-Vault-Token: $token" \
            -X POST "$VAULT_ADDR/v1/auth/token/renew-self" 2>&1)"; then
            echo "vault-cli: HTTP error renewing token: $response" >&2
            exit 2
        fi
    fi
    # Print the granted lease duration (seconds) so a renewer loop can log it.
    printf '%s' "$response" | jq -r '.auth.lease_duration // empty'
}

# @trace spec:tillandsias-vault, spec:git-mirror-service
# Probe the mounted token's own validity/TTL (token-auth endpoint). Used by the
# relay to DISTINGUISH an expired mirror token (this call 403s → exit 2 → the
# fix is "relaunch the forge to re-mint") from a genuinely-absent GitHub token
# (this call succeeds but `read secret/github/token` fails → "run GitHub
# Login"). Without this discriminator the relay reported every mirror-token
# expiry as a missing GitHub credential — the false error operators chased.
cmd_lookup_self() {
    field=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -field=*) field="${1#-field=}"; shift ;;
            --field=*) field="${1#--field=}"; shift ;;
            -field|--field) shift; field="$1"; shift ;;
            *) break ;;
        esac
    done
    token="$(read_token)"
    if ! body="$(curl --cacert "$VAULT_CACERT" -fsS -H "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/auth/token/lookup-self" 2>&1)"; then
        echo "vault-cli: HTTP error on lookup-self (token expired or invalid): $body" >&2
        exit 2
    fi
    if [ -n "$field" ]; then
        value="$(printf '%s' "$body" | jq -r ".data.${field} // empty")"
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            echo "vault-cli: field '$field' missing or null on lookup-self" >&2
            exit 3
        fi
        printf '%s' "$value"
    else
        printf '%s' "$body"
    fi
}

# Gate every network-touching subcommand on a readable CA bundle in ONE place,
# so no future subcommand can silently reach Vault unverified by forgetting to
# call require_cacert itself. usage/help do no I/O and are exempt.
case "${1:-}" in
    read|write|write-stdin|renew-self|lookup-self|health) require_cacert ;;
esac

case "${1:-}" in
    read) shift; cmd_read "$@" ;;
    write) shift; cmd_write "$@" ;;
    write-stdin) shift; cmd_write_stdin "$@" ;;
    renew-self) shift; cmd_renew_self "$@" ;;
    lookup-self) shift; cmd_lookup_self "$@" ;;
    health) cmd_health ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) echo "vault-cli: unknown subcommand: $1" >&2; usage; exit 4 ;;
esac
