#!/usr/bin/env bash
# Tillandsias repo-key generator.
#
# Two modes:
#
# 1. --mode=gpg (legacy default for older release scripts):
#    Generate an RSA-4096 GPG key for APT/RPM repository signing.
#    Outputs `repo-key.gpg` (public) and `repo-key-private.gpg`. The
#    private key is intended to be stored as the REPO_GPG_PRIVATE_KEY
#    GitHub secret and the file deleted immediately. This path is kept
#    for the historical release contract; the active release path uses
#    Cosign and does not require GPG.
#
# 2. --mode=deploy (Tillandsias init flow):
#    Generate an ed25519 SSH deploy key for the project's GitHub repo
#    and persist the private key in the host keyring via Secret Service
#    (libsecret on Linux, Keychain on macOS). Stores the corresponding
#    public key fingerprint in .tillandsias/config.toml so the tray /
#    headless can re-fetch the private key by name. The forge container
#    NEVER sees the private key — it speaks plain git over the enclave
#    network to the git-service container, which signs with the key
#    extracted from the host keyring on demand.
#
# Usage:
#   ./scripts/generate-repo-key.sh                 # legacy GPG (default)
#   ./scripts/generate-repo-key.sh --mode=gpg      # explicit GPG
#   ./scripts/generate-repo-key.sh --mode=deploy   # SSH deploy key
#       [--project <name>]    # default: $(basename "$PWD")
#       [--config <path>]     # default: .tillandsias/config.toml
#       [--comment <text>]    # default: tillandsias-<project>@<host>
#       [--dry-run]           # print actions, do not write anything
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  unsupported mode or missing dependency
#   3  keyring write failed
#
# @trace spec:gh-auth-script, spec:secrets-management, spec:native-secrets-store
# @cheatsheet utils/podman-secrets.md, runtime/forge-paths-ephemeral-vs-persistent.md

set -euo pipefail

# Parse arguments.
MODE="gpg"
PROJECT=""
CONFIG_PATH=""
KEY_COMMENT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=*)         MODE="${1#--mode=}"; shift ;;
        --mode)           shift; MODE="$1"; shift ;;
        --project=*)      PROJECT="${1#--project=}"; shift ;;
        --project)        shift; PROJECT="$1"; shift ;;
        --config=*)       CONFIG_PATH="${1#--config=}"; shift ;;
        --config)         shift; CONFIG_PATH="$1"; shift ;;
        --comment=*)      KEY_COMMENT="${1#--comment=}"; shift ;;
        --comment)        shift; KEY_COMMENT="$1"; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

_log()  { printf '[generate-repo-key] %s\n' "$*" >&2; }
_die()  { printf '[generate-repo-key] error: %s\n' "$*" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Mode: legacy GPG
# ---------------------------------------------------------------------------
mode_gpg() {
    command -v gpg >/dev/null 2>&1 || _die "gpg not found" 2

    if [[ "$DRY_RUN" == true ]]; then
        _log "[dry-run] would generate Tillandsias Release GPG key"
        return 0
    fi

    gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: Tillandsias Release
Name-Email: releases@tillandsias.dev
Expire-Date: 0
%commit
EOF

    gpg --armor --export "Tillandsias Release" > repo-key.gpg
    gpg --armor --export-secret-keys "Tillandsias Release" > repo-key-private.gpg
    _log "Public key: repo-key.gpg (commit to repo)"
    _log "Private key: repo-key-private.gpg (store as GitHub secret REPO_GPG_PRIVATE_KEY)"
    _log "DELETE repo-key-private.gpg after storing as secret!"
}

# ---------------------------------------------------------------------------
# Mode: SSH deploy key (Tillandsias init flow)
# ---------------------------------------------------------------------------

# secret_store_set <service> <account> <secret>
# Writes a secret into the host keyring via Secret Service (Linux),
# Keychain (macOS), or falls back to an error on unsupported platforms.
# @trace spec:native-secrets-store, spec:secrets-management
secret_store_set() {
    local service="$1" account="$2" secret="$3"

    case "$(uname -s)" in
        Linux)
            command -v secret-tool >/dev/null 2>&1 \
                || _die "secret-tool not found (install libsecret-tools)" 2
            printf '%s' "$secret" | secret-tool store --label "$service ($account)" \
                service "$service" account "$account" \
                || return 3
            ;;
        Darwin)
            command -v security >/dev/null 2>&1 \
                || _die "macOS 'security' tool not found" 2
            # Update-or-create: delete first (ignore failure), then add
            security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || true
            security add-generic-password -s "$service" -a "$account" -w "$secret" \
                || return 3
            ;;
        *)
            _die "unsupported platform for keyring write: $(uname -s)" 2
            ;;
    esac
}

# secret_store_get <service> <account>
# Reads a secret from the host keyring.
secret_store_get() {
    local service="$1" account="$2"

    case "$(uname -s)" in
        Linux)
            command -v secret-tool >/dev/null 2>&1 \
                || _die "secret-tool not found (install libsecret-tools)" 2
            secret-tool lookup service "$service" account "$account"
            ;;
        Darwin)
            command -v security >/dev/null 2>&1 \
                || _die "macOS 'security' tool not found" 2
            security find-generic-password -s "$service" -a "$account" -w
            ;;
        *)
            _die "unsupported platform for keyring read: $(uname -s)" 2
            ;;
    esac
}

# Compute a stable account name for the deploy key in the keyring.
deploy_key_account_name() {
    local project="$1"
    printf 'tillandsias-deploy-key:%s' "$project"
}

mode_deploy() {
    command -v ssh-keygen >/dev/null 2>&1 || _die "ssh-keygen not found" 2

    : "${PROJECT:=$(basename "$PWD")}"
    : "${CONFIG_PATH:=.tillandsias/config.toml}"
    : "${KEY_COMMENT:=tillandsias-${PROJECT}@$(hostname -s 2>/dev/null || echo localhost)}"

    local tmpdir keyfile pubfile fingerprint pub_line
    tmpdir=$(mktemp -d -t tillandsias-repo-key.XXXXXX)
    # `tmpdir` is a local in this function, so a global EXIT trap can't see it.
    # Use RETURN to clean up before mode_deploy returns to the dispatcher.
    trap 'rm -rf -- "$tmpdir"' RETURN
    keyfile="$tmpdir/id_ed25519"
    pubfile="$keyfile.pub"

    _log "Generating ed25519 deploy key for project '$PROJECT'"
    _log "Comment: $KEY_COMMENT"

    if [[ "$DRY_RUN" == true ]]; then
        _log "[dry-run] would: ssh-keygen -t ed25519 -N '' -C '$KEY_COMMENT' -f '$keyfile'"
        _log "[dry-run] would: store private key in keyring as service=tillandsias account=$(deploy_key_account_name "$PROJECT")"
        _log "[dry-run] would: write fingerprint into $CONFIG_PATH"
        return 0
    fi

    ssh-keygen -t ed25519 -N '' -C "$KEY_COMMENT" -f "$keyfile" -q
    pub_line=$(cat "$pubfile")
    fingerprint=$(ssh-keygen -lf "$pubfile" | awk '{print $2}')

    local account
    account=$(deploy_key_account_name "$PROJECT")

    _log "Writing private key into host keyring (service=tillandsias account=$account)"
    secret_store_set "tillandsias" "$account" "$(cat "$keyfile")" \
        || _die "keyring write failed; private key NOT stored" 3

    # Round-trip read to confirm the key landed.
    local readback
    readback=$(secret_store_get "tillandsias" "$account" 2>/dev/null || true)
    if [[ -z "$readback" || "$readback" != "$(cat "$keyfile")" ]]; then
        _die "keyring read-back mismatch; private key was not stored correctly" 3
    fi

    # Persist the public key + fingerprint in the project config so the
    # tray/headless can recover the right key by name.
    mkdir -p "$(dirname "$CONFIG_PATH")"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        cat >"$CONFIG_PATH" <<EOF
# Tillandsias project configuration.
# @trace spec:gh-auth-script, spec:secrets-management
[project]
name = "$PROJECT"

EOF
    fi

    # Replace any existing [deploy_key] section with the freshly generated one.
    local tmpconf="$tmpdir/config.toml"
    awk '
        BEGIN { skip=0 }
        /^\[deploy_key\]/ { skip=1; next }
        skip && /^\[/      { skip=0 }
        skip               { next }
        { print }
    ' "$CONFIG_PATH" >"$tmpconf"

    cat >>"$tmpconf" <<EOF

[deploy_key]
# @trace spec:gh-auth-script
# Private key lives in the host keyring; never in this file or any forge
# container. Use \`secret-tool lookup service tillandsias account
# $account\` to retrieve it on the host.
algorithm = "ed25519"
fingerprint = "$fingerprint"
keyring_service = "tillandsias"
keyring_account = "$account"
public_key = "$pub_line"
EOF

    mv "$tmpconf" "$CONFIG_PATH"
    _log "Wrote deploy key metadata to $CONFIG_PATH"
    _log "Public key (add to GitHub repo deploy keys, write access):"
    printf '\n%s\n\n' "$pub_line"
    _log "Done."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
    gpg)    mode_gpg ;;
    deploy) mode_deploy ;;
    *)      _die "unknown --mode value '$MODE' (expected gpg|deploy)" 2 ;;
esac
