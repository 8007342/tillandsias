#!/usr/bin/env bash
# @trace spec:git-mirror-service
#
# test-mirror-host-cert-and-sshd.sh — order 749-54pv (design T4+T5,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# Proves, IN the real images/git container under the 749-wv4d posture
# (--read-only --cap-drop=ALL --user 1000, writable state on /tmp only), the
# packet's four exit criteria:
#
#   1. the presented host key is a CERTIFICATE for exactly the one principal
#      git-<mirror-id>, and a client carrying only the @cert-authority line
#      connects with StrictHostKeyChecking=yes;
#   2. AuthorizedKeysFile none is EFFECTIVE (a plain key is refused while a
#      CA-signed cert with the right principal is accepted) and the
#      AuthorizedPrincipalsFile carries exactly one opaque line;
#   3. NEGATIVE CONTROL — a host cert with a second principal, and an extra
#      principals line, are each REFUSED with a named cause;
#   4. the re-request loop is exercised (interval shrunk from the 8 h default),
#      re-issuing with a new serial and SIGHUPing sshd.
#
# Hermetic: the Vault signer is stubbed through TILLANDSIAS_SSH_SIGNER_CMD with
# a fixture CA driven by ssh-keygen — byte-equivalent to what
# ssh-host-signer/sign/host-<mirror-id> returns. The live two-project matrix
# belongs to 722-uern, not here.
#
# GRAMMAR — exactly one final line per mode:
#   ok:hostcert-fixture:<what> | fail:hostcert-fixture:<cause>
# `all` ends with: 'ok: all mirror-host-cert scenarios passed'

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MODE="${1:-all}"
IMAGE_TAG="localhost/tillandsias-git:latest"
MID="fixt0mirror0id0abcd"

build_image() {
    if ! scripts/build-image.sh git >/tmp/.hostcert-build.log 2>&1; then
        echo "fail:hostcert-fixture:image-build-failed (see /tmp/.hostcert-build.log)"
        exit 1
    fi
}

run_inner() {
    podman run --rm \
        --read-only --cap-drop=ALL --user 1000 \
        --tmpfs /tmp:rw,mode=1777 \
        -v "$ROOT/images/git/sshd-identity.sh:/usr/local/bin/sshd-identity.sh:ro,z" \
        --entrypoint /bin/bash \
        "$IMAGE_TAG" -c "$PRELUDE
$1" 2>&1
}

# Shared in-container prelude: fixture CAs, stub signer, receive stub.
PRELUDE='set -u
export TILLANDSIAS_MIRROR_ID='"$MID"'
mkdir -p /tmp/fx/ca /tmp/fx/client /tmp/fx/home
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/host_ca
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'\''SEOF'\''
#!/bin/bash
pub="$1"; principal="$2"
n=$(( $(cat /tmp/fx/sign-count 2>/dev/null || echo 0) + 1 )); echo $n > /tmp/fx/sign-count
p="$principal"; [ "${FIXTURE_EVIL_PRINCIPALS:-0}" = 1 ] && p="$principal,evil-second-principal"
d=$(mktemp -d); cp "$pub" "$d/k.pub"
ssh-keygen -q -s /tmp/fx/ca/host_ca -I fixture-host -h -n "$p" -z "$n" "$d/k.pub" || exit 1
cat "$d/k-cert.pub"
SEOF
chmod +x /tmp/fx/signer.sh
printf "#!/bin/sh\necho RECEIVE-MARKER\n" > /tmp/fx/receive-stub
chmod +x /tmp/fx/receive-stub
export TILLANDSIAS_SSH_SIGNER_CMD=/tmp/fx/signer.sh
export TILLANDSIAS_TRUSTED_USER_CA_FILE=/tmp/fx/ca/client_ca.pub
export TILLANDSIAS_RECEIVE_PATH=/tmp/fx/receive-stub
CERT=/tmp/tillandsias-sshd/ssh_host_ed25519_key-cert.pub'

INNER_CERT_EXACT='
out="$(/usr/local/bin/sshd-identity.sh request-cert)" || { echo "inner:request-failed:$out"; exit 90; }
L="$(ssh-keygen -L -f "$CERT")" || { echo "inner:cert-unreadable"; exit 91; }
echo "$L" | grep -q "host certificate" || { echo "inner:not-host-cert"; exit 92; }
P="$(echo "$L" | awk "/^ *Principals:/{f=1;next} /^ *(Critical Options|Extensions):/{f=0} f&&NF{print \$1}")"
[ "$(printf "%s\n" "$P" | grep -c .)" = "1" ] || { echo "inner:principal-count:$P"; exit 93; }
[ "$P" = "git-'"$MID"'" ] || { echo "inner:principal-value:$P"; exit 94; }
echo inner:cert-exact'

INNER_CA_TRUST='
/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; sed -n "1,8p" /tmp/tillandsias-sshd/sshd.err >&2; exit 90; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/key
ssh-keygen -q -s /tmp/fx/ca/client_ca -I lane-fixture -n "til:forge-push:'"$MID"'" /tmp/fx/client/key.pub
printf "@cert-authority git-'"$MID"' %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
out="$(ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o HostKeyAlias=git-'"$MID"' \
    -i /tmp/fx/client/key -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh.err)"
echo "$out" | grep -q RECEIVE-MARKER || { echo inner:cert-client-not-accepted; sed -n "1,6p" /tmp/fx/ssh.err >&2; exit 91; }
printf "@cert-authority git-'"$MID"' %s\n" "$(cat /tmp/fx/ca/client_ca.pub)" > /tmp/fx/kh-wrong
if ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh-wrong \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o HostKeyAlias=git-'"$MID"' \
    -i /tmp/fx/client/key -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh2.err; then
  echo inner:wrong-ca-accepted; exit 92
fi
grep -qi "host key verification failed\|No ED25519 host key is known\|not in the trusted" /tmp/fx/ssh2.err \
    || { echo inner:wrong-ca-wrong-cause; sed -n "1,6p" /tmp/fx/ssh2.err >&2; exit 93; }
echo inner:ca-trust-ok'

INNER_OUTSIDE_CA='
/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; exit 90; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/plain
printf "@cert-authority git-'"$MID"' %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
if out="$(ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o PasswordAuthentication=no \
    -o HostKeyAlias=git-'"$MID"' \
    -i /tmp/fx/client/plain -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh.err)"; then
  echo inner:plain-key-accepted; exit 91
fi
echo "$out" | grep -q RECEIVE-MARKER && { echo inner:plain-key-ran-command; exit 92; }
grep -qi "permission denied" /tmp/fx/ssh.err || { echo inner:plain-key-wrong-cause; sed -n "1,6p" /tmp/fx/ssh.err >&2; exit 93; }
L="$(cat /tmp/tillandsias-sshd/authorized_principals)"
[ "$L" = "til:forge-push:'"$MID"'" ] || { echo inner:principals-content; exit 94; }
[ "$(grep -c . /tmp/tillandsias-sshd/authorized_principals)" = "1" ] || { echo inner:principals-lines; exit 95; }
echo inner:outside-ca-refused'

INNER_NEGATIVES='
out="$(FIXTURE_EVIL_PRINCIPALS=1 /usr/local/bin/sshd-identity.sh request-cert)"; rc=$?
[ $rc -ne 0 ] || { echo inner:evil-cert-accepted; exit 90; }
echo "$out" | grep -q "fail:sshd-identity:cert-principal-violation" || { echo "inner:evil-cert-wrong-cause:$out"; exit 91; }
mkdir -p /tmp/tillandsias-sshd
printf "til:forge-push:'"$MID"'\nevil-extra-line\n" > /tmp/tillandsias-sshd/authorized_principals
out="$(/usr/local/bin/sshd-identity.sh render-config)"; rc=$?
[ $rc -ne 0 ] || { echo inner:extra-line-accepted; exit 92; }
echo "$out" | grep -q "fail:sshd-identity:principals-violation" || { echo "inner:extra-line-wrong-cause:$out"; exit 93; }
echo inner:negatives-refused'

INNER_RENEWAL='
export TILLANDSIAS_HOST_CERT_RENEW_SECONDS=1
/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; exit 90; }
s1="$(ssh-keygen -L -f "$CERT" | awk "/Serial:/{print \$2}")"
sleep 3.5
n="$(cat /tmp/fx/sign-count)"
[ "$n" -ge 2 ] || { echo "inner:no-reissue:count=$n"; exit 91; }
s2="$(ssh-keygen -L -f "$CERT" | awk "/Serial:/{print \$2}")"
[ "$s2" != "$s1" ] || { echo "inner:serial-unchanged:$s1"; exit 92; }
grep -q renewed /tmp/tillandsias-sshd/renew.log || { echo inner:no-renew-log; exit 93; }
kill -0 "$(cat /tmp/tillandsias-sshd/sshd.pid)" 2>/dev/null || { echo inner:sshd-died; exit 94; }
echo inner:renewal-ok'

mode_render_default() {
    # Host-side, no podman: the DEFAULT rendered config pins the T5 directive
    # set verbatim, including the production ForceCommand path (fixtures above
    # override it; the default must stay the design's).
    d="$(mktemp -d)"
    out="$(TILLANDSIAS_MIRROR_ID="$MID" TILLANDSIAS_SSH_DIR="$d" \
        bash images/git/sshd-identity.sh render-config 2>&1)"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "fail:hostcert-fixture:render-default-rc-$rc:$out"; rm -rf "$d"; return 1
    fi
    for want in \
        'AuthorizedKeysFile none' \
        "TrustedUserCAKeys $d/trusted-user-ca.pub" \
        "AuthorizedPrincipalsFile $d/authorized_principals" \
        'ForceCommand /usr/local/bin/tillandsias-receive' \
        'ExposeAuthInfo yes' \
        'AllowTcpForwarding no' \
        'AllowAgentForwarding no' \
        'PermitTTY no' \
        "RevokedKeys $d/revoked_keys" \
        'LogLevel VERBOSE'; do
        if ! grep -qxF "$want" "$d/sshd_config"; then
            echo "fail:hostcert-fixture:t5-directive-missing:$want"; rm -rf "$d"; return 1
        fi
    done
    [ "$(cat "$d/authorized_principals")" = "til:forge-push:$MID" ] \
        || { echo "fail:hostcert-fixture:principals-default"; rm -rf "$d"; return 1; }
    rm -rf "$d"
    echo "ok:hostcert-fixture:t5-directives-rendered"
}

run_mode() {
    inner="$1"; want="$2"; okline="$3"
    out="$(run_inner "$inner")"
    if printf '%s' "$out" | grep -q "$want"; then
        echo "$okline"
        return 0
    fi
    printf '%s\n' "$out" | tail -8 >&2
    echo "fail:hostcert-fixture:${okline#ok:hostcert-fixture:}"
    return 1
}

case "$MODE" in
    render-default) mode_render_default ;;
    cert-exactness) build_image; run_mode "$INNER_CERT_EXACT" inner:cert-exact ok:hostcert-fixture:cert-exact-single-principal ;;
    ca-trust-connect) build_image; run_mode "$INNER_CA_TRUST" inner:ca-trust-ok ok:hostcert-fixture:ca-only-client-connects ;;
    outside-ca) build_image; run_mode "$INNER_OUTSIDE_CA" inner:outside-ca-refused ok:hostcert-fixture:keys-outside-ca-refused ;;
    negative-principal) build_image; run_mode "$INNER_NEGATIVES" inner:negatives-refused ok:hostcert-fixture:negatives-refused ;;
    renewal) build_image; run_mode "$INNER_RENEWAL" inner:renewal-ok ok:hostcert-fixture:renewal-exercised ;;
    all)
        rc=0
        mode_render_default || rc=1
        build_image
        run_mode "$INNER_CERT_EXACT" inner:cert-exact ok:hostcert-fixture:cert-exact-single-principal || rc=1
        run_mode "$INNER_CA_TRUST" inner:ca-trust-ok ok:hostcert-fixture:ca-only-client-connects || rc=1
        run_mode "$INNER_OUTSIDE_CA" inner:outside-ca-refused ok:hostcert-fixture:keys-outside-ca-refused || rc=1
        run_mode "$INNER_NEGATIVES" inner:negatives-refused ok:hostcert-fixture:negatives-refused || rc=1
        run_mode "$INNER_RENEWAL" inner:renewal-ok ok:hostcert-fixture:renewal-exercised || rc=1
        if [ $rc -eq 0 ]; then
            echo "ok: all mirror-host-cert scenarios passed"
        else
            echo "fail:hostcert-fixture:one-or-more-scenarios"
        fi
        exit $rc
        ;;
    *) echo "usage: $0 [render-default|cert-exactness|ca-trust-connect|outside-ca|negative-principal|renewal|all]"; exit 2 ;;
esac
