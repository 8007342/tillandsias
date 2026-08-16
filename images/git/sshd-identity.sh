#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:tillandsias-vault
#
# sshd-identity.sh — order 749-54pv (design T4+T5,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# T4: request a HOST certificate from Vault's `ssh-host-signer/sign/host-<mirror-id>`
#     with the mirror's existing Vault Agent token, for EXACTLY the principal
#     `git-<mirror-id>` (D9), write it beside the host key, and re-request every
#     8 h (SIGHUP makes sshd present the fresh cert).
# T5: render the sshd_config that trusts ONLY the client CA:
#     AuthorizedKeysFile none, TrustedUserCAKeys, a per-project
#     AuthorizedPrincipalsFile containing exactly `til:forge-push:<mirror-id>`
#     (one opaque line, D3), ForceCommand tillandsias-receive, ExposeAuthInfo yes,
#     AllowTcpForwarding no, AllowAgentForwarding no, PermitTTY no, RevokedKeys,
#     LogLevel VERBOSE.
#
# The mirror VALIDATES what the signer returns before installing it: a cert
# that is not a host certificate, carries zero or multiple principals, or names
# any principal other than git-<mirror-id> is REFUSED (exit criterion 3 — the
# single-principal claim is falsifiable in this script, not only in Vault's
# role config). The principals file is likewise refused if it would carry
# anything but the single opaque line.
#
# Runs entirely as uid 1000 under --read-only/--cap-drop=ALL (749-wv4d posture):
# every writable path lives under TILLANDSIAS_SSH_DIR on the /tmp tmpfs.
#
# GRAMMAR — exactly one final line per subcommand:
#   ok:sshd-identity:<what> | fail:sshd-identity:<cause>     (exit 0 / non-zero)
#
# Subcommands:
#   request-cert   issue-or-renew the host certificate (validated, atomic)
#   render-config  write sshd_config + authorized_principals + revoked_keys
#   validate-cert <cert-file>   standalone validator (used by fixtures)
#   ensure         full T4+T5: key, cert, config, sshd, renewal loop
#   renew-loop     the 8 h re-request loop (interval overridable for fixtures)
#
# Environment:
#   TILLANDSIAS_MIRROR_ID                required — opaque D13 id (lowercase)
#   TILLANDSIAS_SSH_DIR                  default /tmp/tillandsias-sshd
#   TILLANDSIAS_SSHD_PORT                default 2222
#   TILLANDSIAS_HOST_CERT_RENEW_SECONDS  default 28800 (8 h; fixtures shrink it)
#   TILLANDSIAS_VAULT_TOKEN_FILE         default /tmp/tillandsias-vault-token
#   VAULT_ADDR / VAULT_CACERT            default https://vault:8200 / /etc/tillandsias/ca.crt
#   TILLANDSIAS_RECEIVE_PATH             default /usr/local/bin/tillandsias-receive
#                                        (T6 lands the wrapper; fixtures override)
#   TILLANDSIAS_TRUSTED_USER_CA_FILE     fixture seam — file with the client CA
#                                        public key; default fetches Vault's
#                                        ssh-client-signer/public_key endpoint
#   TILLANDSIAS_SSH_SIGNER_CMD           fixture seam — command invoked as
#                                        `$CMD <pubkey-file> <principal>` that
#                                        prints a signed cert on stdout. EMPTY in
#                                        production (Vault signs). Fixtures use it
#                                        to stub the signer hermetically.

set -uo pipefail

MID="${TILLANDSIAS_MIRROR_ID:-}"
DIR="${TILLANDSIAS_SSH_DIR:-/tmp/tillandsias-sshd}"
PORT="${TILLANDSIAS_SSHD_PORT:-2222}"
RENEW_SECONDS="${TILLANDSIAS_HOST_CERT_RENEW_SECONDS:-28800}"
TOKEN_FILE="${TILLANDSIAS_VAULT_TOKEN_FILE:-/tmp/tillandsias-vault-token}"
VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
VAULT_CACERT="${VAULT_CACERT:-/etc/tillandsias/ca.crt}"
RECEIVE_PATH="${TILLANDSIAS_RECEIVE_PATH:-/usr/local/bin/tillandsias-receive}"
# T6 (749-2fqj): sshd sessions do NOT inherit the container environment, so the
# wrapper's fixed-path resolution travels via SetEnv in the rendered config.
# Defaults follow the entrypoint's own variables when present.
RECEIVE_PROJECT="${TILLANDSIAS_RECEIVE_PROJECT:-${PROJECT:-}}"
RECEIVE_ROOT="${TILLANDSIAS_RECEIVE_ROOT:-${TILLANDSIAS_GIT_SERVICE_ROOT:-/srv/git}}"
CA_FILE="${TILLANDSIAS_TRUSTED_USER_CA_FILE:-}"
SIGNER_CMD="${TILLANDSIAS_SSH_SIGNER_CMD:-}"

HOST_KEY="$DIR/ssh_host_ed25519_key"
HOST_CERT="$HOST_KEY-cert.pub"
PRINCIPALS_FILE="$DIR/authorized_principals"
TRUSTED_CA="$DIR/trusted-user-ca.pub"
REVOKED="$DIR/revoked_keys"
CONFIG="$DIR/sshd_config"
SSHD_PID_FILE="$DIR/sshd.pid"
COUNT_FILE="$DIR/cert-issuance-count"
RENEW_LOG="$DIR/renew.log"

die() { echo "fail:sshd-identity:$1"; exit 1; }

require_mid() {
    [ -n "$MID" ] || die "no-mirror-id"
    case "$MID" in
        *[!a-z0-9]*) die "mirror-id-grammar" ;;
    esac
}

# ── Signing ────────────────────────────────────────────────────────────────
# Production: POST the public key to ssh-host-signer/sign/host-<mirror-id>
# with cert_type=host and valid_principals=git-<mirror-id>. The role's
# allowed_domains is exactly git-<mirror-id> (722-hthz), but the request asks
# for the exact principal anyway and the validator below re-checks the RESULT —
# defense in depth over trusting either end alone.
sign_host_key() {
    _pub="$1"
    if [ -n "$SIGNER_CMD" ]; then
        "$SIGNER_CMD" "$_pub" "git-$MID"
        return $?
    fi
    [ -r "$TOKEN_FILE" ] || { echo "no-vault-token" >&2; return 1; }
    _payload="$(jq -n --rawfile pk "$_pub" --arg p "git-$MID" \
        '{public_key: $pk, cert_type: "host", valid_principals: $p}')" || return 1
    curl -sf --cacert "$VAULT_CACERT" \
        -H "X-Vault-Token: $(cat "$TOKEN_FILE")" \
        -X POST -d "$_payload" \
        "$VAULT_ADDR/v1/ssh-host-signer/sign/host-$MID" \
        | jq -re '.data.signed_key'
}

# ── Validation (exit criterion 3 lives here) ──────────────────────────────
cert_principals() {
    ssh-keygen -L -f "$1" 2>/dev/null \
        | awk '/^ *Principals:/{f=1;next} /^ *(Critical Options|Extensions):/{f=0} f&&NF{print $1}'
}

validate_cert_file() {
    _cert="$1"
    ssh-keygen -L -f "$_cert" >/dev/null 2>&1 || { echo "cert-unreadable"; return 1; }
    ssh-keygen -L -f "$_cert" 2>/dev/null | grep -q 'host certificate' \
        || { echo "cert-not-host-type"; return 1; }
    _principals="$(cert_principals "$_cert")"
    _count="$(printf '%s\n' "$_principals" | grep -c . || true)"
    if [ "$_count" != "1" ] || [ "$_principals" != "git-$MID" ]; then
        echo "cert-principal-violation"
        return 1
    fi
    return 0
}

request_cert() {
    require_mid
    mkdir -p "$DIR" && chmod 700 "$DIR" || die "dir-unwritable"
    if [ ! -f "$HOST_KEY" ]; then
        ssh-keygen -q -N '' -t ed25519 -f "$HOST_KEY" || die "host-keygen-failed"
    fi
    _tmp="$DIR/.cert.tmp.$$"
    if ! sign_host_key "$HOST_KEY.pub" > "$_tmp" 2>"$DIR/.sign.err" || [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        die "sign-request-failed:$(head -c 120 "$DIR/.sign.err" 2>/dev/null | tr '\n' ' ')"
    fi
    if _why="$(validate_cert_file "$_tmp")"; then :; else
        rm -f "$_tmp"
        die "${_why:-cert-invalid}"
    fi
    mv -f "$_tmp" "$HOST_CERT" || die "cert-install-failed"
    _n="$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))"
    echo "$_n" > "$COUNT_FILE"
    echo "ok:sshd-identity:cert-issued"
}

# ── T5 rendering ───────────────────────────────────────────────────────────
write_principals() {
    _want="til:forge-push:$MID"
    if [ -f "$PRINCIPALS_FILE" ] && [ "$(cat "$PRINCIPALS_FILE")" != "$_want" ]; then
        die "principals-violation"
    fi
    printf '%s\n' "$_want" > "$PRINCIPALS_FILE.tmp" && mv -f "$PRINCIPALS_FILE.tmp" "$PRINCIPALS_FILE" \
        || die "principals-unwritable"
    # Refuse to proceed if the installed file is anything but the single line.
    [ "$(grep -c . "$PRINCIPALS_FILE")" = "1" ] || die "principals-violation"
    [ "$(cat "$PRINCIPALS_FILE")" = "$_want" ] || die "principals-violation"
}

ensure_trusted_ca() {
    if [ -n "$CA_FILE" ]; then
        [ -s "$CA_FILE" ] || die "trusted-ca-file-empty"
        cp -f "$CA_FILE" "$TRUSTED_CA" || die "trusted-ca-unwritable"
        return 0
    fi
    # The client-signer public key is public material; Vault serves it
    # unauthenticated at /v1/ssh-client-signer/public_key.
    if ! curl -sf --cacert "$VAULT_CACERT" \
        "$VAULT_ADDR/v1/ssh-client-signer/public_key" > "$TRUSTED_CA" \
        || [ ! -s "$TRUSTED_CA" ]; then
        die "trusted-ca-fetch-failed"
    fi
}

render_config() {
    require_mid
    mkdir -p "$DIR" && chmod 700 "$DIR" || die "dir-unwritable"
    write_principals
    : >> "$REVOKED" || die "revoked-keys-unwritable"
    # The directive set is design T5, verbatim. PasswordAuthentication and
    # KbdInteractiveAuthentication are additionally pinned off so that
    # "no key material is authorised outside the CA" cannot be bypassed by a
    # password lane — additive hardening consistent with the design's intent.
    cat > "$CONFIG.tmp" <<EOF || die "config-unwritable"
# Rendered by sshd-identity.sh (749-54pv, design T5). Do not edit in place.
Port $PORT
ListenAddress 0.0.0.0
HostKey $HOST_KEY
HostCertificate $HOST_CERT
AuthorizedKeysFile none
TrustedUserCAKeys $TRUSTED_CA
AuthorizedPrincipalsFile $PRINCIPALS_FILE
ForceCommand $RECEIVE_PATH
# T6 (749-2fqj): the wrapper's fixed-path inputs. Sessions inherit no container
# env; these are the ONLY channel, and the wrapper fails loud when they are
# empty rather than guessing a repository.
SetEnv TILLANDSIAS_RECEIVE_ROOT=$RECEIVE_ROOT TILLANDSIAS_RECEIVE_PROJECT=$RECEIVE_PROJECT TILLANDSIAS_MIRROR_ID=$MID
ExposeAuthInfo yes
AllowTcpForwarding no
AllowAgentForwarding no
PermitTTY no
RevokedKeys $REVOKED
LogLevel VERBOSE
PasswordAuthentication no
KbdInteractiveAuthentication no
HostbasedAuthentication no
# StrictModes must be off: the 749-wv4d posture confines ALL writable state to
# the /tmp tmpfs (mode 1777), and OpenSSH's secure_filename() refuses any
# config file whose ancestry is world-writable — even with the sticky bit.
# Compensating controls: this renderer verifies the principals file is the
# single exact opaque line (and refuses otherwise), $DIR is chmod 700, and the
# rootfs is --read-only with --cap-drop=ALL.
StrictModes no
PidFile none
EOF
    mv -f "$CONFIG.tmp" "$CONFIG" || die "config-install-failed"
    echo "ok:sshd-identity:config-rendered"
}

# ── Renewal (exit criterion 4) ─────────────────────────────────────────────
renew_loop() {
    require_mid
    while :; do
        sleep "$RENEW_SECONDS"
        if request_cert >/dev/null; then
            if [ -f "$SSHD_PID_FILE" ] && kill -HUP "$(cat "$SSHD_PID_FILE")" 2>/dev/null; then
                echo "$(date -u +%FT%TZ) renewed issuance=$(cat "$COUNT_FILE")" >> "$RENEW_LOG"
            else
                echo "$(date -u +%FT%TZ) fail:sshd-identity:renew-hup-failed" >> "$RENEW_LOG"
                echo "fail:sshd-identity:renew-hup-failed" >&2
            fi
        else
            # Loud, and keep looping: the current cert stays valid until its
            # TTL; a transient Vault outage must not take the lane down.
            echo "$(date -u +%FT%TZ) fail:sshd-identity:renew-sign-failed" >> "$RENEW_LOG"
            echo "fail:sshd-identity:renew-sign-failed" >&2
        fi
    done
}

ensure() {
    require_mid
    request_cert >/dev/null || exit 1
    ensure_trusted_ca
    render_config >/dev/null || exit 1
    /usr/sbin/sshd -D -e -f "$CONFIG" 2>"$DIR/sshd.err" &
    echo $! > "$SSHD_PID_FILE"
    _up=0
    for _ in $(seq 1 50); do
        if nc -w 1 127.0.0.1 "$PORT" </dev/null 2>/dev/null | head -c 8 | grep -q 'SSH-2.0-'; then
            _up=1; break
        fi
        sleep 0.2
    done
    if [ "$_up" != "1" ]; then
        sed -n '1,10p' "$DIR/sshd.err" >&2
        die "sshd-not-listening"
    fi
    renew_loop &
    echo $! > "$DIR/renew-loop.pid"
    echo "ok:sshd-identity:ready"
}

case "${1:-}" in
    request-cert)   request_cert ;;
    render-config)  render_config ;;
    validate-cert)
        require_mid
        if _why="$(validate_cert_file "${2:?cert file required}")"; then
            echo "ok:sshd-identity:cert-valid"
        else
            die "${_why:-cert-invalid}"
        fi
        ;;
    ensure)         ensure ;;
    renew-loop)     renew_loop ;;
    *) die "usage:request-cert|render-config|validate-cert|ensure|renew-loop" ;;
esac
