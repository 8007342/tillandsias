-- @env PATH HOME
-- @trace spec:git-mirror-service, spec:tillandsias-vault, order:749-6uby, order:1342-r4pv, order:2373-8vq6
--
-- test-ssh-lane-sidecar.lua — ssh-lane-sidecar.sh holds a lane's one-principal user certificate and
-- serves it from an agent. Ported from the .sh of the same name (2373-8vq6). The signer is a fixture CA;
-- arm 4 is a real `vault server -dev` inside the container. No enclave, no live vault.
--
--   1 ensure: a ready line with the fingerprint, a socket, the key served
--   2 NEGATIVE CONTROLS a host-type, a two-principal and a wrong-principal cert are refused by name
--   3 renewal past MaxAuthTries, the agent alive and its identities bounded
--   4 a lane policy signs on its own path and gets 403 on any other
--
-- Usage: tillandsias-plan script run scripts/lua/test-ssh-lane-sidecar.lua
-- Verdict: ok:ssh-lane-sidecar:<n> arms | violation:... | skip:...:no-podman

local fixture = require "common.fixture"
local gitimage = require "common.gitimage"
local T = fixture.new("ssh-lane-sidecar")
local PRELUDE = [==[
set -u
export TILLANDSIAS_MIRROR_ID=fixt0lane0id0abcdefg
export TILLANDSIAS_SKIP_VAULT_AGENT=1
export TILLANDSIAS_AGENT_SOCK_DIR=/tmp/fx/sock
mkdir -p /tmp/fx/ca /tmp/fx/sock /tmp/fx/home
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'SEOF'
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
SOCK=/tmp/fx/sock/agent.sock
]==]
local READY = [==[

/usr/local/bin/ssh-lane-sidecar ensure > /tmp/fx/out 2>/tmp/fx/err &
SIDEPID=$!
for i in $(seq 1 20); do grep -q "ok:ssh-lane-sidecar:ready" /tmp/fx/out 2>/dev/null && break; sleep 0.5; done
grep -q "ok:ssh-lane-sidecar:ready fingerprint=SHA256:" /tmp/fx/out || { echo "inner:no-ready-line"; cat /tmp/fx/out /tmp/fx/err >&2; exit 90; }
grep -q "mirror=fixt0lane0id0abcdefg" /tmp/fx/out || { echo "inner:no-mirror-in-ready"; exit 91; }
[ -S "$SOCK" ] || { echo "inner:no-socket"; exit 92; }
LISTING="$(SSH_AUTH_SOCK=$SOCK ssh-add -l 2>&1)" || { echo "inner:agent-list-failed:$LISTING"; exit 93; }
grep -q <<<"$LISTING" "til-lane-fixt0lane0id0abcdefg" || { echo "inner:key-not-served:$LISTING"; exit 94; }
kill $SIDEPID 2>/dev/null
echo inner:ready-and-served
]==]
local NEGATIVES = [==[

FIXTURE_HOST_TYPE=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n1 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-cert-not-user-type" /tmp/fx/n1 || { echo "inner:host-type-not-refused"; cat /tmp/fx/n1 >&2; exit 90; }
rm -rf /tmp/tillandsias-ssh-lane
FIXTURE_TWO_PRINCIPALS=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n2 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-principal-count-2" /tmp/fx/n2 || { echo "inner:two-principals-not-refused"; cat /tmp/fx/n2 >&2; exit 91; }
rm -rf /tmp/tillandsias-ssh-lane
FIXTURE_WRONG_PRINCIPAL=1 /usr/local/bin/ssh-lane-sidecar request-cert > /tmp/fx/n3 2>&1
grep -q "fail:ssh-lane-sidecar:cert-invalid-principal-mismatch" /tmp/fx/n3 || { echo "inner:wrong-principal-not-refused"; cat /tmp/fx/n3 >&2; exit 92; }
echo inner:negatives-refused
]==]
local RENEWAL = [==[

export TILLANDSIAS_CLIENT_CERT_RENEW_SECONDS=1
/usr/local/bin/ssh-lane-sidecar ensure > /tmp/fx/out 2>/tmp/fx/err &
SIDEPID=$!
for i in $(seq 1 20); do grep -q "ok:ssh-lane-sidecar:ready" /tmp/fx/out 2>/dev/null && break; sleep 0.5; done
sleep 12
COUNT=$(cat /tmp/tillandsias-ssh-lane/cert-issuance-count 2>/dev/null || echo 0)
[ "$COUNT" -ge 2 ] || { echo "inner:renewal-count:$COUNT"; cat /tmp/fx/out /tmp/fx/err >&2; exit 90; }
SSH_AUTH_SOCK=$SOCK ssh-add -l >/dev/null 2>&1 || { echo "inner:agent-died-after-renew"; exit 91; }
# Past the cliff by construction, or the assertion that follows is vacuous.
[ "$COUNT" -gt 6 ] || { echo "inner:renewals-did-not-pass-maxauthtries:$COUNT"; cat /tmp/fx/out /tmp/fx/err >&2; exit 93; }
# THE BOUND. Expected is 2: the bare key and exactly ONE certificate. The
# broken code reaches COUNT+1 here and the lane is already dead at 7.
IDS=$(SSH_AUTH_SOCK=$SOCK ssh-add -l 2>/dev/null | grep -c .)
[ "$IDS" -le 3 ] || { echo "inner:agent-identity-leak:$IDS after $COUNT renewals"; SSH_AUTH_SOCK=$SOCK ssh-add -l >&2; exit 92; }
kill $SIDEPID 2>/dev/null
echo "inner:renewed:$COUNT:ids:$IDS"
]==]
local M2 = [==[

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
echo inner:m2-exact-path-403
]==]
local G = gitimage.new(T)
for _, c in ipairs{ { "1 ready line, socket and a served key", READY, "inner:ready-and-served" }, { "2 NEGATIVE CONTROLS each bad certificate is refused by name", NEGATIVES, "inner:negatives-refused" },
    { "3 renewal past MaxAuthTries keeps the agent and bounds its identities", RENEWAL, "inner:renewed:" }, { "4 a lane signs on its own path and gets 403 on another", M2, "inner:m2-exact-path-403" } } do
    local x = G:run(PRELUDE .. c[2], { env = { HOME = "/tmp/fx/home" }, mounts = { ["images/git/ssh-lane-sidecar.sh"] = "/usr/local/bin/ssh-lane-sidecar" }, timeout_ms = 180000 })
    T:arm(c[1], text.contains("\n" .. x.out, "\n" .. c[3]), x.why)
end
T:finish()
