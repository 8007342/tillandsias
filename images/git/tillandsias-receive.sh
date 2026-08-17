#!/bin/sh
# @trace spec:git-mirror-service
#
# tillandsias-receive — order 749-2fqj (design T6,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# The sshd ForceCommand for the authenticated push lane (749-54pv renders
# `ForceCommand /usr/local/bin/tillandsias-receive`). Contract:
#
#   * The requested TARGET in $SSH_ORIGINAL_COMMAND is deliberately IGNORED
#     (§4a row M5): presenting a certificate already selected the repository,
#     because the cert only authenticates against THIS mirror's principals
#     file. A receive-pack aimed at project B's path still lands in this
#     mirror's fixed repository — path traversal through the request line is
#     structurally impossible.
#   * Only the receive verb exists on this lane. Clones/fetches ride the
#     anonymous git:// daemon; anything but git-receive-pack is refused loud.
#   * $SSH_USER_AUTH (ExposeAuthInfo yes) carries the certificate that
#     authenticated this session. The four TILLANDSIAS_PUSH_* variables the
#     audit rung consumes (design §"audit fields", T9/722-uern) are parsed
#     from the CERT — never from anything the client typed — and exported
#     before exec so pre-/post-receive hooks can log and enforce them:
#       TILLANDSIAS_PUSH_KEY_FP      SHA256:… fingerprint of the presented cert
#       TILLANDSIAS_PUSH_PRINCIPAL   til:forge-push:<mirror-id>
#       TILLANDSIAS_PUSH_SERIAL      cert serial (changes per renewal; joins KRL)
#       TILLANDSIAS_PUSH_KEY_ID      the signer's key id
#
# Fixed-path resolution comes from the sshd_config SetEnv rendered by
# sshd-identity.sh (sshd sessions do NOT inherit the container environment),
# with the same names overridable for offline fixtures.
#
# GRAMMAR — on refusal exactly one stderr line:
#   fail:tillandsias-receive:<cause>   (exit 1)
# On success this process becomes git-receive-pack (exec) and emits nothing.

set -u

fail() {
    echo "fail:tillandsias-receive:$1" >&2
    exit 1
}

ROOT="${TILLANDSIAS_RECEIVE_ROOT:-/srv/git}"
PROJECT="${TILLANDSIAS_RECEIVE_PROJECT:-}"
[ -n "$PROJECT" ] || fail "no-project"
case "$PROJECT" in
    */*|.*) fail "project-grammar" ;;
esac
REPO="$ROOT/$PROJECT"
[ -d "$REPO" ] || fail "fixed-repo-missing"

case "${SSH_ORIGINAL_COMMAND:-}" in
    git-receive-pack\ *|git\ receive-pack\ *) : ;;
    *) fail "not-receive-pack" ;;
esac

AUTH="${SSH_USER_AUTH:-}"
[ -n "$AUTH" ] && [ -r "$AUTH" ] || fail "no-auth-info"

# The auth-info line for a certificate: `publickey <cert-type> <base64>`.
CERT_LINE="$(awk '$1 == "publickey" && $2 ~ /-cert-v01@openssh\.com$/ { print $2 " " $3; exit }' "$AUTH")"
[ -n "$CERT_LINE" ] || fail "no-cert-in-auth-info"

CERT_TMP="$(mktemp "${TMPDIR:-/tmp}/tillandsias-receive-cert.XXXXXX")" || fail "tmp-unwritable"
printf '%s\n' "$CERT_LINE" > "$CERT_TMP"

CERT_TEXT="$(ssh-keygen -L -f "$CERT_TMP" 2>/dev/null)" || { rm -f "$CERT_TMP"; fail "cert-unparseable"; }
KEY_FP="$(ssh-keygen -l -f "$CERT_TMP" 2>/dev/null | awk '{print $2; exit}')"
rm -f "$CERT_TMP"

PRINCIPAL="$(printf '%s\n' "$CERT_TEXT" \
    | awk '/^ *Principals:/{f=1;next} /^ *(Critical Options|Extensions):/{f=0} f&&NF{print $1; exit}')"
SERIAL="$(printf '%s\n' "$CERT_TEXT" | awk '/^ *Serial:/{print $2; exit}')"
KEY_ID="$(printf '%s\n' "$CERT_TEXT" | sed -n 's/^ *Key ID: "\(.*\)"$/\1/p' | head -n 1)"

[ -n "$KEY_FP" ]    || fail "cert-fingerprint-missing"
[ -n "$PRINCIPAL" ] || fail "cert-principal-missing"
[ -n "$SERIAL" ]    || fail "cert-serial-missing"
[ -n "$KEY_ID" ]    || fail "cert-key-id-missing"

TILLANDSIAS_PUSH_KEY_FP="$KEY_FP"
TILLANDSIAS_PUSH_PRINCIPAL="$PRINCIPAL"
TILLANDSIAS_PUSH_SERIAL="$SERIAL"
TILLANDSIAS_PUSH_KEY_ID="$KEY_ID"
export TILLANDSIAS_PUSH_KEY_FP TILLANDSIAS_PUSH_PRINCIPAL TILLANDSIAS_PUSH_SERIAL TILLANDSIAS_PUSH_KEY_ID

# GIT_RECEIVE_PACK is an offline-fixture seam only (the PATH-interposed
# recorder); production always execs the real binary.
exec "${TILLANDSIAS_GIT_RECEIVE_PACK:-git-receive-pack}" "$REPO"
