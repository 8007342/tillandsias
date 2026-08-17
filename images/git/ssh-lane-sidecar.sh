#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:tillandsias-vault
#
# ssh-lane-sidecar.sh — order 749-6uby (design T8,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# The per-lane ssh-agent sidecar: the ONE place a lane's SSH private key ever
# exists. The forge receives only the agent SOCKET (a named volume) and public
# CA trust — D5, the invariant the whole design rests on. Flow:
#
#   1. Vault Agent auto-auth (reuses vault-agent-bootstrap + the
#      /run/secrets/vault-approle mount, exactly like the mirror entrypoint)
#      under the per-lane AppRole `ssh-lane-signer-<mirror-id>` (D6), whose
#      minted policy permits exactly ONE path:
#      `ssh-client-signer/sign/<mirror-id>` (D12). A 403 from any other path
#      is CORRECT behavior (§4a M2), not an outage.
#   2. ssh-keygen on tmpfs (/tmp) — the key never touches a volume or image
#      layer.
#   3. Sign the public key for exactly the principal
#      `til:forge-push:<mirror-id>` (D3) and VALIDATE the result before
#      serving it: a cert that is not a user certificate, carries zero or
#      multiple principals, or names any other principal is REFUSED — the
#      single-principal claim stays falsifiable here, not only in Vault's
#      role config (same posture as sshd-identity.sh).
#   4. ssh-agent bound to $TILLANDSIAS_AGENT_SOCK_DIR/agent.sock (the named
#      volume the forge mounts), ssh-add key+cert.
#   5. Renewal loop: re-sign and re-add before the 30m TTL lapses
#      (default every 20m; fixtures shrink it). Re-adding the same key
#      replaces the agent entry atomically from the client's view.
#
# Runs as uid 1000 under --read-only/--cap-drop=ALL (749-wv4d posture):
# every writable path is /tmp tmpfs or the socket volume.
#
# GRAMMAR — exactly one final line per subcommand; the launcher greps the
# ready line from `podman logs` for the attribution ledger:
#   ok:ssh-lane-sidecar:ready fingerprint=SHA256:... mirror=<mirror-id>
#   ok:ssh-lane-sidecar:<what> | fail:ssh-lane-sidecar:<cause>
#
# Subcommands:
#   ensure        full T8: auth, keygen, sign, validate, agent, renew loop
#   request-cert  one issuance (used by ensure and the renew loop)
#   validate-cert <cert-file>  standalone validator (fixtures)
#   renew-loop    the renewal loop alone (interval overridable)
#
# Environment:
#   TILLANDSIAS_MIRROR_ID                  required — opaque D13 id
#   TILLANDSIAS_AGENT_SOCK_DIR             default /ssh-agent (named volume)
#   TILLANDSIAS_SSH_LANE_DIR               default /tmp/tillandsias-ssh-lane
#   TILLANDSIAS_CLIENT_CERT_RENEW_SECONDS  default 1200 (20m; fixtures shrink)
#   TILLANDSIAS_VAULT_TOKEN_FILE           default /tmp/tillandsias-vault-token
#   VAULT_ADDR / VAULT_CACERT              default https://vault:8200 / /etc/tillandsias/ca.crt
#   TILLANDSIAS_SSH_SIGNER_CMD             fixture seam — `$CMD <pubkey> <principal>`
#                                          prints a signed USER cert on stdout.
#                                          EMPTY in production (Vault signs).
#   TILLANDSIAS_SKIP_VAULT_AGENT           fixture seam — 1 skips auto-auth
#                                          (SIGNER_CMD or a pre-seeded token
#                                          file provides signing instead).

set -uo pipefail

MID="${TILLANDSIAS_MIRROR_ID:-}"
SOCK_DIR="${TILLANDSIAS_AGENT_SOCK_DIR:-/ssh-agent}"
LANE_DIR="${TILLANDSIAS_SSH_LANE_DIR:-/tmp/tillandsias-ssh-lane}"
RENEW_SECONDS="${TILLANDSIAS_CLIENT_CERT_RENEW_SECONDS:-1200}"
TOKEN_FILE="${TILLANDSIAS_VAULT_TOKEN_FILE:-/tmp/tillandsias-vault-token}"
VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
VAULT_CACERT="${VAULT_CACERT:-/etc/tillandsias/ca.crt}"
SIGNER_CMD="${TILLANDSIAS_SSH_SIGNER_CMD:-}"
SKIP_AGENT="${TILLANDSIAS_SKIP_VAULT_AGENT:-0}"

SOCK="$SOCK_DIR/agent.sock"
KEY="$LANE_DIR/id_ed25519"
CERT="$KEY-cert.pub"
COUNT_FILE="$LANE_DIR/cert-issuance-count"
AGENT_PID_FILE="$LANE_DIR/agent.pid"

die() { echo "fail:ssh-lane-sidecar:$1"; exit 1; }

require_mid() {
    [ -n "$MID" ] || die "no-mirror-id"
    case "$MID" in
        *[!a-z0-9]*) die "mirror-id-grammar" ;;
    esac
}

principal() { echo "til:forge-push:$MID"; }

# ── Signing ────────────────────────────────────────────────────────────────
# Production: POST the public key to ssh-client-signer/sign/<mirror-id> with
# cert_type=user and valid_principals=til:forge-push:<mirror-id>. The minted
# policy names exactly this path (D12); the validator below re-checks the
# RESULT — defense in depth over trusting either end alone.
sign_user_key() {
    _pub="$1"
    if [ -n "$SIGNER_CMD" ]; then
        "$SIGNER_CMD" "$_pub" "$(principal)"
        return $?
    fi
    [ -r "$TOKEN_FILE" ] || { echo "no-vault-token" >&2; return 1; }
    _payload="$(jq -n --rawfile pk "$_pub" --arg p "$(principal)" \
        '{public_key: $pk, cert_type: "user", valid_principals: $p}')" || return 1
    curl -sf --cacert "$VAULT_CACERT" \
        -H "X-Vault-Token: $(cat "$TOKEN_FILE")" \
        -X POST -d "$_payload" \
        "$VAULT_ADDR/v1/ssh-client-signer/sign/$MID" \
        | jq -re '.data.signed_key'
}

# ── Validation (the falsifiable single-principal claim) ───────────────────
cert_principals() {
    ssh-keygen -L -f "$1" 2>/dev/null \
        | awk '/^ *Principals:/{f=1;next} /^ *(Critical Options|Extensions):/{f=0} f&&NF{print $1}'
}

validate_cert_file() {
    _cert="$1"
    ssh-keygen -L -f "$_cert" >/dev/null 2>&1 || { echo "cert-unreadable"; return 1; }
    ssh-keygen -L -f "$_cert" 2>/dev/null | grep -q 'user certificate' \
        || { echo "cert-not-user-type"; return 1; }
    _principals="$(cert_principals "$_cert")"
    _count="$(printf '%s\n' "$_principals" | grep -c . || true)"
    [ "$_count" = "1" ] || { echo "principal-count-$_count"; return 1; }
    [ "$_principals" = "$(principal)" ] || { echo "principal-mismatch"; return 1; }
    return 0
}

# ── Vault Agent auto-auth (mirror entrypoint idiom) ────────────────────────
VAULT_AGENT_BOOTSTRAP="${VAULT_AGENT_BOOTSTRAP:-/usr/local/bin/vault-agent-bootstrap}"
VAULT_AGENT_START_TIMEOUT="${VAULT_AGENT_START_TIMEOUT:-30}"
VAULT_AGENT_PID=""

start_vault_agent() {
    [ "$SKIP_AGENT" = "1" ] && return 0
    [ -n "$SIGNER_CMD" ] && return 0
    if [ ! -r /run/secrets/vault-approle ]; then
        echo "fail:ssh-lane-sidecar:no-approle-secret" >&2
        return 1
    fi
    [ -x "$VAULT_AGENT_BOOTSTRAP" ] || { echo "bootstrap-missing" >&2; return 1; }
    rm -f "$TOKEN_FILE"
    "$VAULT_AGENT_BOOTSTRAP" &
    VAULT_AGENT_PID=$!
    _waited=0
    while [ "$_waited" -lt "$VAULT_AGENT_START_TIMEOUT" ]; do
        [ -s "$TOKEN_FILE" ] && return 0
        kill -0 "$VAULT_AGENT_PID" 2>/dev/null || { echo "agent-died" >&2; return 1; }
        sleep 1
        _waited=$((_waited + 1))
    done
    echo "agent-timeout" >&2
    return 1
}

# ── Issuance ────────────────────────────────────────────────────────────────
request_cert() {
    require_mid
    mkdir -p "$LANE_DIR" || die "lane-dir"
    chmod 0700 "$LANE_DIR" 2>/dev/null || true
    if [ ! -f "$KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "til-lane-$MID" -f "$KEY" || die "keygen"
    fi
    _new="$LANE_DIR/.cert.new"
    if ! sign_user_key "$KEY.pub" > "$_new" || [ ! -s "$_new" ]; then
        rm -f "$_new"
        die "sign-request-failed"
    fi
    _why="$(validate_cert_file "$_new")" || { rm -f "$_new"; die "cert-invalid-$_why"; }
    mv "$_new" "$CERT" || die "cert-install"
    _n="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
    echo $((_n + 1)) > "$COUNT_FILE"
    echo "ok:ssh-lane-sidecar:cert-issued n=$((_n + 1))"
}

fingerprint() { ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}'; }

agent_add() {
    SSH_AUTH_SOCK="$SOCK" ssh-add -q "$KEY" 2>/dev/null || return 1
    return 0
}

# ── Renewal loop ────────────────────────────────────────────────────────────
renew_loop() {
    require_mid
    while :; do
        sleep "$RENEW_SECONDS" &
        _sleep_pid=$!
        wait "$_sleep_pid" || true
        if out="$(request_cert)"; then
            if agent_add; then
                echo "ok:ssh-lane-sidecar:renewed $(echo "$out" | sed 's/^ok:ssh-lane-sidecar:cert-issued //')"
            else
                echo "fail:ssh-lane-sidecar:renew-agent-add" >&2
            fi
        else
            # Loud, not fatal: the previous cert stays valid until its TTL;
            # the next tick retries. A sidecar that dies on one blip takes
            # the lane's push capability with it.
            echo "fail:ssh-lane-sidecar:renew-issuance" >&2
        fi
    done
}

# ── Full ensure ─────────────────────────────────────────────────────────────
ensure() {
    require_mid
    [ -d "$SOCK_DIR" ] || die "sock-dir-missing"
    start_vault_agent || die "vault-agent"
    request_cert >/dev/null || exit 1
    rm -f "$SOCK"
    # -D keeps the agent in this process group; run it in the background and
    # supervise from the renew loop so container pid 1 stays this script.
    ssh-agent -D -a "$SOCK" >/dev/null 2>&1 &
    _agent=$!
    echo "$_agent" > "$AGENT_PID_FILE"
    _waited=0
    while [ ! -S "$SOCK" ] && [ "$_waited" -lt 10 ]; do sleep 0.5; _waited=$((_waited + 1)); done
    [ -S "$SOCK" ] || die "agent-socket"
    # The socket volume is shared with exactly one forge (same uid). Group
    # rwx on the dir, socket owned 0600-by-agent is fine: same uid connects.
    agent_add || die "agent-add"
    trap 'kill -TERM "$_agent" 2>/dev/null; [ -n "$VAULT_AGENT_PID" ] && kill -TERM "$VAULT_AGENT_PID" 2>/dev/null; exit 0' TERM INT
    echo "ok:ssh-lane-sidecar:ready fingerprint=$(fingerprint) mirror=$MID"
    renew_loop
}

case "${1:-ensure}" in
    ensure)        ensure ;;
    request-cert)  request_cert ;;
    validate-cert) shift; _why="$(validate_cert_file "${1:?cert file}")" \
                       && echo "ok:ssh-lane-sidecar:cert-valid" \
                       || die "cert-invalid-$_why" ;;
    renew-loop)    renew_loop ;;
    *)             die "usage-unknown-subcommand" ;;
esac
