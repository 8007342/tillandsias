#!/usr/bin/env bash
# @trace order:1313-prin, spec:git-mirror-service, spec:tillandsias-vault
#
# tillandsias-host-push-cert.sh — mint THIS host's ssh push certificate, on
# demand, and REFUSE anything that is not exactly what was asked for.
#
# WHY ON DEMAND AND NOT A DAEMON. The certificate's TTL is 30 minutes. A
# resident agent renews on a loop (that is the per-lane sidecar's job); a
# workstation that pushes a few times a day should mint at push time instead —
# no long-running process, and "one mint per TTL" stays literally true.
#
# WHY THE KEYRING IS NOT ON THIS PATH, which is the whole point of the design.
# The AppRole document was written to a 0600 plain file at PROVISION time, when
# the launcher had already read the root token once. This script reads that
# file. A `git push` therefore makes NO secret-service call — and on this fleet
# such a call can abort gnome-keyring 50 in its own GetProperty handler
# (1265-8qr6), which costs the operator an unlock and the host its credential.
#
# WHAT THE MATERIAL CAN DO, so the tradeoff is legible: one AppRole, one
# policy, exactly `ssh-client-signer/sign/host-<host>`. It cannot read
# secret/github/token, cannot sign for another host, and cannot sign a HOST
# certificate.
#
# VALIDATION IS AT THE CLIENT, not only in Vault's role config. Vault is asked
# for one principal and its role permits only one — and this checks the
# returned certificate anyway, because a claim that is only enforced where it
# is issued is not falsifiable where it is used. Same posture as
# sshd-identity.sh and ssh-lane-sidecar.sh, which both re-validate what the
# signer hands back.
#
# Verdicts, one line on stdout:
#   ok:host-push-cert:<path>          a valid cert is installed (exit 0)
#   fail:host-push-cert:<cause>       nothing usable was installed (exit 1)
#   skip:host-push-cert:<reason>      not applicable here (exit 0)
set -uo pipefail

HOST="${TILLANDSIAS_HOST_PUSH_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
[ -n "$HOST" ] || { echo "fail:host-push-cert:no-host-name"; exit 1; }

CONF_BASE="${XDG_CONFIG_HOME:-$HOME/.config}/tillandsias/host-push"
KEY="$CONF_BASE/$HOST.ed25519"
CERT="$KEY-cert.pub"
DOC="$CONF_BASE/$HOST.approle.json"
VAULT_ADDR_HOST="${TILLANDSIAS_VAULT_ADDR:-https://127.0.0.1:8201}"
CACERT="${TILLANDSIAS_VAULT_CACERT:-$HOME/.local/state/tillandsias/ca/intermediate.crt}"
PRINCIPAL="til:host-push:$HOST"

command -v jq  >/dev/null 2>&1 || { echo "skip:host-push-cert:no-jq"; exit 0; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "skip:host-push-cert:no-ssh-keygen"; exit 0; }
[ -r "$DOC" ] || { echo "fail:host-push-cert:no-approle-document:$DOC"; exit 1; }
[ -r "$CACERT" ] || { echo "fail:host-push-cert:no-ca:$CACERT"; exit 1; }

umask 077
mkdir -p "$CONF_BASE" || { echo "fail:host-push-cert:conf-dir-unwritable"; exit 1; }

# The private key never leaves this host and is never regenerated while a valid
# one exists: re-keying would invalidate nothing (certs are short-lived) but it
# would churn the authorized principals' audit trail for no gain.
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "$PRINCIPAL" -f "$KEY" </dev/null \
        || { echo "fail:host-push-cert:keygen"; exit 1; }
fi

_role_id="$(jq -r '.role_id // empty' "$DOC" 2>/dev/null)"
_secret_id="$(jq -r '.secret_id // empty' "$DOC" 2>/dev/null)"
[ -n "$_role_id" ] && [ -n "$_secret_id" ] \
    || { echo "fail:host-push-cert:approle-document-incomplete"; exit 1; }

# CAPTURE THEN TEST (795-imz3): a pipeline verdict here would invert under
# pipefail, and this one decides whether a credential is used.
_login="$(curl -s --cacert "$CACERT" -X POST \
    -d "{\"role_id\":\"$_role_id\",\"secret_id\":\"$_secret_id\"}" \
    "$VAULT_ADDR_HOST/v1/auth/approle/login" 2>/dev/null)"
_token="$(printf '%s' "$_login" | jq -r '.auth.client_token // empty' 2>/dev/null)"
[ -n "$_token" ] || { echo "fail:host-push-cert:approle-login-refused"; exit 1; }

_pub="$(cat "$KEY.pub" 2>/dev/null)"
[ -n "$_pub" ] || { echo "fail:host-push-cert:no-public-key"; exit 1; }

_payload="$(jq -n --arg pk "$_pub" --arg p "$PRINCIPAL" \
    '{public_key: $pk, cert_type: "user", valid_principals: $p}' 2>/dev/null)"
_resp="$(curl -s --cacert "$CACERT" -H "X-Vault-Token: $_token" -X POST \
    -d "$_payload" \
    "$VAULT_ADDR_HOST/v1/ssh-client-signer/sign/host-$HOST" 2>/dev/null)"
_signed="$(printf '%s' "$_resp" | jq -r '.data.signed_key // empty' 2>/dev/null)"
if [ -z "$_signed" ]; then
    _err="$(printf '%s' "$_resp" | jq -r '.errors // [] | join("; ")' 2>/dev/null)"
    echo "fail:host-push-cert:sign-refused:${_err:-no-signed-key}"
    exit 1
fi

_tmp="$CERT.tmp.$$"
printf '%s\n' "$_signed" > "$_tmp" || { echo "fail:host-push-cert:cert-unwritable"; exit 1; }

# ── Validation: exit criterion 3's posture, applied at the CLIENT ───────────
_dump="$(ssh-keygen -L -f "$_tmp" 2>/dev/null)"
case "$_dump" in
    *"user certificate"*) ;;
    *) rm -f "$_tmp"; echo "fail:host-push-cert:not-a-user-certificate"; exit 1 ;;
esac

# Principals are the indented lines under `Principals:` up to the next header.
_principals="$(printf '%s' "$_dump" | awk '
    /^ *Principals:/ {f=1; next}
    /^ *(Critical Options|Extensions):/ {f=0}
    f && NF {print $1}')"
_n="$(printf '%s' "$_principals" | grep -c . )"
if [ "$_n" != "1" ]; then
    rm -f "$_tmp"
    echo "fail:host-push-cert:principal-count:$_n"
    exit 1
fi
if [ "$_principals" != "$PRINCIPAL" ]; then
    rm -f "$_tmp"
    echo "fail:host-push-cert:wrong-principal:$_principals"
    exit 1
fi

mv -f "$_tmp" "$CERT" || { echo "fail:host-push-cert:cert-install"; exit 1; }
echo "ok:host-push-cert:$CERT"
