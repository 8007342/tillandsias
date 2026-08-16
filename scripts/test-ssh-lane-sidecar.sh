#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:tillandsias-vault
#
# test-ssh-lane-sidecar.sh — order 749-6uby (design T8,
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md).
#
# Proves, IN the real images/git container under the 749-wv4d posture, the
# sidecar half of the packet's exit criteria:
#
#   1. ensure: keygen on tmpfs, seam-signed USER cert validated, ssh-agent
#      serving on the socket, the ready line carries the fingerprint the
#      launcher harvests for attribution;
#   2. NEGATIVE CONTROLS — a host-type cert, a two-principal cert, and a
#      wrong-principal cert are each REFUSED with a named cause (the
#      single-principal claim stays falsifiable in the sidecar itself);
#   3. the renewal loop is exercised (interval shrunk from the 20m default),
#      re-issuing and re-adding while the agent keeps serving;
#   4. §4a M2 against a REAL Vault (in-container `vault server -dev`): a
#      token holding exactly the minted lane policy signs via its OWN
#      `ssh-client-signer/sign/<mid>` path and receives HTTP 403 from any
#      OTHER mirror's path. The policy body is byte-shaped like
#      `render_lane_signer_policy_hcl` mints (exact path, no wildcard).
#
# Hermetic: no enclave stack, no live vault container. The LIVE M0 (two real
# launched lanes) and the in-forge D5 re-verification belong to the packet's
# hold note, not here.
#
# GRAMMAR — one `ok:lane-fixture:<what>` line per scenario;
# `all` ends with: 'ok: all ssh-lane-sidecar scenarios passed'

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MODE="${1:-all}"
IMAGE_TAG="localhost/tillandsias-git:latest"
MID="fixt0lane0id0abcdefg"

ensure_image() {
    podman image exists "$IMAGE_TAG" && return 0
    # 766-7zqf guard: build-image.sh regenerates plan/metrics-dashboard.md
    # from this environment's (empty) telemetry — snapshot and restore.
    cp plan/metrics-dashboard.md /tmp/.lane-dashboard.bak 2>/dev/null || true
    if ! scripts/build-image.sh git >/tmp/.lane-image-build.log 2>&1; then
        echo "fail:lane-fixture:image-build-failed (see /tmp/.lane-image-build.log)"
        exit 1
    fi
    if [ -f /tmp/.lane-dashboard.bak ]; then
        cp /tmp/.lane-dashboard.bak plan/metrics-dashboard.md || true
    fi
}

run_inner() {
    podman run --rm \
        --read-only --cap-drop=ALL --user 1000 \
        --tmpfs /tmp:rw,mode=1777 \
        --env HOME=/tmp/fx/home \
        -v "$ROOT/images/git/ssh-lane-sidecar.sh:/usr/local/bin/ssh-lane-sidecar:ro,z" \
        --entrypoint /bin/bash \
        "$IMAGE_TAG" -c "$PRELUDE
$1" 2>&1
}

# Shared in-container prelude: fixture client CA + a stub signer that mints
# USER certs (force-command included, like Vault's role default_critical_options)
# and supports the negative-control knobs.
PRELUDE='set -u
export TILLANDSIAS_MIRROR_ID='"$MID"'
export TILLANDSIAS_SKIP_VAULT_AGENT=1
export TILLANDSIAS_AGENT_SOCK_DIR=/tmp/fx/sock
mkdir -p /tmp/fx/ca /tmp/fx/sock /tmp/fx/home
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'\''SEOF'\''
#!/bin/bash
pub="$1"; principal="$2"
n=$(( $(cat /tmp/fx/sign-count 2>/dev/null || echo 0) + 1 )); echo $n > /tmp/fx/sign-count
p="$principal"
[ "${FIXTURE_TWO_PRINCIPALS:-0}" = 1 ] && p="$principal,evil-second"
[ "${FIXTURE_WRONG_PRINCIPAL:-0}" = 1 ] && p="til:forge-push:othermirror"
hostflag=""
[ "${FIXTURE_HOST_TYPE:-0}" = 1 ] && hostflag="-h"
d=$(mktemp -d); cp "$pub" "$d/k.pub"
ssh-keygen -q -s /tmp/fx/ca/client_ca -I lane-fixture $hostflag -n "$p" -z "$n" \
    -O force-command=/usr/local/bin/tillandsias-receive "$d/k.pub" || exit 1
cat "$d/k-cert.pub"
SEOF
chmod +x /tmp/fx/signer.sh
export TILLANDSIAS_SSH_SIGNER_CMD=/tmp/fx/signer.sh
SOCK=/tmp/fx/sock/agent.sock'

INNER_READY='
/usr/local/bin/ssh-lane-sidecar ensure > /tmp/fx/out 2>/tmp/fx/err &
SIDEPID=$!
for i in $(seq 1 20); do grep -q "ok:ssh-lane-sidecar:ready" /tmp/fx/out 2>/dev/null && break; sleep 0.5; done
grep -q "ok:ssh-lane-sidecar:ready fingerprint=SHA256:" /tmp/fx/out || { echo "inner:no-ready-line"; cat /tmp/fx/out /tmp/fx/err >&2; exit 90; }
grep -q "mirror='"$MID"'" /tmp/fx/out || { echo "inner:no-mirror-in-ready"; exit 91; }
[ -S "$SOCK" ] || { echo "inner:no-socket"; exit 92; }
LISTING="$(SSH_AUTH_SOCK=$SOCK ssh-add -l 2>&1)" || { echo "inner:agent-list-failed:$LISTING"; exit 93; }
echo "$LISTING" | grep -q "til-lane-'"$MID"'" || { echo "inner:key-not-served:$LISTING"; exit 94; }
kill $SIDEPID 2>/dev/null
echo inner:ready-and-served'

INNER_NEGATIVES='
FIXTURE_HOST_TYPE=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n1 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-cert-not-user-type" /tmp/fx/n1 || { echo "inner:host-type-not-refused"; cat /tmp/fx/n1 >&2; exit 90; }
rm -rf /tmp/tillandsias-ssh-lane
FIXTURE_TWO_PRINCIPALS=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n2 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-principal-count-2" /tmp/fx/n2 || { echo "inner:two-principals-not-refused"; cat /tmp/fx/n2 >&2; exit 91; }
rm -rf /tmp/tillandsias-ssh-lane
FIXTURE_WRONG_PRINCIPAL=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n3 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-principal-mismatch" /tmp/fx/n3 || { echo "inner:wrong-principal-not-refused"; cat /tmp/fx/n3 >&2; exit 92; }
echo inner:negatives-refused'

INNER_RENEWAL='
export TILLANDSIAS_CLIENT_CERT_RENEW_SECONDS=2
/usr/local/bin/ssh-lane-sidecar ensure > /tmp/fx/out 2>/tmp/fx/err &
SIDEPID=$!
for i in $(seq 1 20); do grep -q "ok:ssh-lane-sidecar:ready" /tmp/fx/out 2>/dev/null && break; sleep 0.5; done
sleep 6
COUNT=$(cat /tmp/tillandsias-ssh-lane/cert-issuance-count 2>/dev/null || echo 0)
[ "$COUNT" -ge 2 ] || { echo "inner:renewal-count:$COUNT"; cat /tmp/fx/out /tmp/fx/err >&2; exit 90; }
SSH_AUTH_SOCK=$SOCK ssh-add -l >/dev/null 2>&1 || { echo "inner:agent-died-after-renew"; exit 91; }
kill $SIDEPID 2>/dev/null
echo "inner:renewed:$COUNT"'

# §4a M2 with a REAL Vault: the minted-shape policy signs ONLY its own path.
INNER_M2='
export HOME=/tmp/fx/home
export VAULT_ADDR=http://127.0.0.1:8200
vault server -dev -dev-root-token-id=fixture-root -dev-listen-address=127.0.0.1:8200 \
    > /tmp/fx/vault.log 2>&1 &
VPID=$!
for i in $(seq 1 30); do curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 && break; sleep 0.5; done
curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null || { echo "inner:vault-not-up"; cat /tmp/fx/vault.log >&2; exit 90; }
export VAULT_TOKEN=fixture-root
vault secrets enable -path=ssh-client-signer ssh >/dev/null || { echo inner:mount-failed; exit 91; }
vault write ssh-client-signer/config/ca generate_signing_key=true >/dev/null || { echo inner:ca-failed; exit 92; }
MIDA=lanemirror0aaaa; MIDB=lanemirror0bbbb
for m in $MIDA $MIDB; do
  vault write "ssh-client-signer/roles/$m" key_type=ca allow_user_certificates=true \
      allowed_users="til:forge-push:$m" default_user=git ttl=30m max_ttl=1h >/dev/null \
      || { echo "inner:role-failed:$m"; exit 93; }
done
# The policy body byte-shaped like render_lane_signer_policy_hcl mints:
# exact path, update only, no wildcard.
printf "path \"ssh-client-signer/sign/%s\" {\n  capabilities = [\"update\"]\n}\n" "$MIDA" \
    | vault policy write "ssh-lane-signer-$MIDA" - >/dev/null || { echo inner:policy-failed; exit 94; }
LANE_TOKEN="$(vault token create -policy="ssh-lane-signer-$MIDA" -field=token)" || { echo inner:token-failed; exit 95; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/lane_key
PAYLOAD="$(jq -n --rawfile pk /tmp/fx/lane_key.pub --arg p "til:forge-push:$MIDA" \
    "{public_key: \$pk, cert_type: \"user\", valid_principals: \$p}")"
OWN=$(curl -s -o /tmp/fx/own.json -w "%{http_code}" -H "X-Vault-Token: $LANE_TOKEN" \
    -X POST -d "$PAYLOAD" "$VAULT_ADDR/v1/ssh-client-signer/sign/$MIDA")
[ "$OWN" = "200" ] || { echo "inner:own-path-status:$OWN"; cat /tmp/fx/own.json >&2; exit 96; }
jq -re ".data.signed_key" /tmp/fx/own.json >/dev/null || { echo inner:own-path-no-cert; exit 97; }
OTHER=$(curl -s -o /tmp/fx/other.json -w "%{http_code}" -H "X-Vault-Token: $LANE_TOKEN" \
    -X POST -d "$PAYLOAD" "$VAULT_ADDR/v1/ssh-client-signer/sign/$MIDB")
[ "$OTHER" = "403" ] || { echo "inner:other-path-status:$OTHER (want 403)"; cat /tmp/fx/other.json >&2; exit 98; }
kill $VPID 2>/dev/null
echo inner:m2-exact-path-403'

scenario_ready() {
    out="$(run_inner "$INNER_READY")"
    echo "$out" | grep -q '^inner:ready-and-served$' \
        && echo "ok:lane-fixture:ready-fingerprint-socket-and-agent-serving" \
        || { echo "fail:lane-fixture:ready ($out)"; return 1; }
}

scenario_negatives() {
    out="$(run_inner "$INNER_NEGATIVES")"
    echo "$out" | grep -q '^inner:negatives-refused$' \
        && echo "ok:lane-fixture:host-type+two-principal+wrong-principal-all-refused" \
        || { echo "fail:lane-fixture:negatives ($out)"; return 1; }
}

scenario_renewal() {
    out="$(run_inner "$INNER_RENEWAL")"
    echo "$out" | grep -q '^inner:renewed:' \
        && echo "ok:lane-fixture:renewal-exercised-and-agent-alive" \
        || { echo "fail:lane-fixture:renewal ($out)"; return 1; }
}

scenario_m2() {
    out="$(run_inner "$INNER_M2")"
    echo "$out" | grep -q '^inner:m2-exact-path-403$' \
        && echo "ok:lane-fixture:m2-own-path-signs-other-path-403" \
        || { echo "fail:lane-fixture:m2 ($out)"; return 1; }
}

ensure_image
rc=0
case "$MODE" in
    ready)    scenario_ready    || rc=1 ;;
    negatives) scenario_negatives || rc=1 ;;
    renewal)  scenario_renewal  || rc=1 ;;
    m2)       scenario_m2       || rc=1 ;;
    all)
        scenario_ready     || rc=1
        scenario_negatives || rc=1
        scenario_renewal   || rc=1
        scenario_m2        || rc=1
        if [ "$rc" = 0 ]; then
            echo "ok: all ssh-lane-sidecar scenarios passed"
        else
            echo "fail: ssh-lane-sidecar scenarios failed"
        fi
        ;;
    *) echo "fail:lane-fixture:unknown-mode"; exit 2 ;;
esac
exit $rc
