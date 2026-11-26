-- @env PATH HOME
-- @trace spec:git-mirror-service, order:749-54pv, order:2373-8vq6
--
-- test-mirror-host-cert-and-sshd.lua — sshd-identity.sh gives the mirror a host CERTIFICATE for one
-- principal and an sshd that trusts only the CA. Ported from the .sh of the same name (2373-8vq6).
-- The Vault signer is a fixture CA behind TILLANDSIAS_SSH_SIGNER_CMD; the rest is the real image.
--
--   1 the default sshd_config carries the directives (no container)
--   2 the host key is a certificate for exactly one principal
--   3 a CA-only client connects, and one trusting the wrong CA does not
--   4 a plain key is refused, and the principals file is one line
--   5 NEGATIVE CONTROL a second principal, or line, is refused by name
--   6 the renewal re-issues with a new serial while sshd keeps serving
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-host-cert-and-sshd.lua
-- Verdict: ok:mirror-host-cert-and-sshd:<n> arms | violation:... | skip:...:no-podman

local fixture = require "common.fixture"
local gitimage = require "common.gitimage"
local T = fixture.new("mirror-host-cert-and-sshd")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local MID = "fixt0mirror0id0abcd"
local PRELUDE = [==[
set -u
export TILLANDSIAS_MIRROR_ID=fixt0mirror0id0abcd
mkdir -p /tmp/fx/ca /tmp/fx/client /tmp/fx/home
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/host_ca
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'SEOF'
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
CERT=/tmp/tillandsias-sshd/ssh_host_ed25519_key-cert.pub
]==]
local CERT_EXACT = [==[

out="$(/usr/local/bin/sshd-identity.sh request-cert)" || { echo "inner:request-failed:$out"; exit 90; }
L="$(ssh-keygen -L -f "$CERT")" || { echo "inner:cert-unreadable"; exit 91; }
grep -q <<<"$L" "host certificate" || { echo "inner:not-host-cert"; exit 92; }
P="$(echo "$L" | awk "/^ *Principals:/{f=1;next} /^ *(Critical Options|Extensions):/{f=0} f&&NF{print \$1}")"
[ "$(printf "%s\n" "$P" | grep -c .)" = "1" ] || { echo "inner:principal-count:$P"; exit 93; }
[ "$P" = "git-fixt0mirror0id0abcd" ] || { echo "inner:principal-value:$P"; exit 94; }
echo inner:cert-exact
]==]
local CA_TRUST = [==[

/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; sed -n "1,8p" /tmp/tillandsias-sshd/sshd.err >&2; exit 90; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/key
ssh-keygen -q -s /tmp/fx/ca/client_ca -I lane-fixture -n "til:forge-push:fixt0mirror0id0abcd" /tmp/fx/client/key.pub
printf "@cert-authority git-fixt0mirror0id0abcd %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
out="$(ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o HostKeyAlias=git-fixt0mirror0id0abcd \
    -i /tmp/fx/client/key -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh.err)"
grep -q <<<"$out" RECEIVE-MARKER || { echo inner:cert-client-not-accepted; sed -n "1,6p" /tmp/fx/ssh.err >&2; exit 91; }
printf "@cert-authority git-fixt0mirror0id0abcd %s\n" "$(cat /tmp/fx/ca/client_ca.pub)" > /tmp/fx/kh-wrong
if ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh-wrong \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o HostKeyAlias=git-fixt0mirror0id0abcd \
    -i /tmp/fx/client/key -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh2.err; then
  echo inner:wrong-ca-accepted; exit 92
fi
grep -qi "host key verification failed\|No ED25519 host key is known\|not in the trusted" /tmp/fx/ssh2.err \
    || { echo inner:wrong-ca-wrong-cause; sed -n "1,6p" /tmp/fx/ssh2.err >&2; exit 93; }
echo inner:ca-trust-ok
]==]
local OUTSIDE_CA = [==[

/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; exit 90; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/plain
printf "@cert-authority git-fixt0mirror0id0abcd %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
if out="$(ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh \
    -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o PasswordAuthentication=no \
    -o HostKeyAlias=git-fixt0mirror0id0abcd \
    -i /tmp/fx/client/plain -p 2222 git@127.0.0.1 true 2>/tmp/fx/ssh.err)"; then
  echo inner:plain-key-accepted; exit 91
fi
grep -q <<<"$out" RECEIVE-MARKER && { echo inner:plain-key-ran-command; exit 92; }
grep -qi "permission denied" /tmp/fx/ssh.err || { echo inner:plain-key-wrong-cause; sed -n "1,6p" /tmp/fx/ssh.err >&2; exit 93; }
L="$(cat /tmp/tillandsias-sshd/authorized_principals)"
[ "$L" = "til:forge-push:fixt0mirror0id0abcd" ] || { echo inner:principals-content; exit 94; }
[ "$(grep -c . /tmp/tillandsias-sshd/authorized_principals)" = "1" ] || { echo inner:principals-lines; exit 95; }
echo inner:outside-ca-refused
]==]
local NEGATIVES = [==[

out="$(FIXTURE_EVIL_PRINCIPALS=1 /usr/local/bin/sshd-identity.sh request-cert)"; rc=$?
[ $rc -ne 0 ] || { echo inner:evil-cert-accepted; exit 90; }
grep -q <<<"$out" "fail:sshd-identity:cert-principal-violation" || { echo "inner:evil-cert-wrong-cause:$out"; exit 91; }
mkdir -p /tmp/tillandsias-sshd
printf "til:forge-push:fixt0mirror0id0abcd\nevil-extra-line\n" > /tmp/tillandsias-sshd/authorized_principals
out="$(/usr/local/bin/sshd-identity.sh render-config)"; rc=$?
[ $rc -ne 0 ] || { echo inner:extra-line-accepted; exit 92; }
grep -q <<<"$out" "fail:sshd-identity:principals-violation" || { echo "inner:extra-line-wrong-cause:$out"; exit 93; }
echo inner:negatives-refused
]==]
local RENEWAL = [==[

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
echo inner:renewal-ok
]==]
local d = T:scratch()
local r = proc.run{ argv = { SH, ROOT .. "/images/git/sshd-identity.sh", "render-config" }, cwd = ROOT, env = { PATH = env.get("PATH"), HOME = d.abs, TILLANDSIAS_MIRROR_ID = MID, TILLANDSIAS_SSH_DIR = d.abs }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
local conf = r.code == 0 and fs.exists(d.rel .. "/sshd_config") and "\n" .. fs.read(d.rel .. "/sshd_config") .. "\n" or ""
local lost = {}
for _, w in ipairs{ "AuthorizedKeysFile none", "TrustedUserCAKeys " .. d.abs .. "/trusted-user-ca.pub", "AuthorizedPrincipalsFile " .. d.abs .. "/authorized_principals", "ForceCommand /usr/local/bin/tillandsias-receive",
    "ExposeAuthInfo yes", "AllowTcpForwarding no", "AllowAgentForwarding no", "PermitTTY no", "RevokedKeys " .. d.abs .. "/revoked_keys", "LogLevel VERBOSE" } do
    if not text.contains(conf, "\n" .. w .. "\n") then lost[#lost + 1] = w end
end
T:arm("1a the default config carries every directive", #lost == 0, table.concat(lost, " | ") .. " rc=" .. tostring(r.code) .. (r.stderr or ""):sub(1, 300))
T:arm("1b and one principal", fs.exists(d.rel .. "/authorized_principals") and text.trim(fs.read(d.rel .. "/authorized_principals")) == "til:forge-push:" .. MID, "differs")
local G = gitimage.new(T)
for _, c in ipairs{ { "2 the host key is a certificate for exactly one principal", CERT_EXACT, "inner:cert-exact" }, { "3 a CA-only client connects, one trusting the wrong CA does not", CA_TRUST, "inner:ca-trust-ok" },
    { "4 a plain key is refused and the principals file is one line", OUTSIDE_CA, "inner:outside-ca-refused" }, { "5 NEGATIVE CONTROL a second principal or line is refused by name", NEGATIVES, "inner:negatives-refused" },
    { "6 renewal re-issues and sshd keeps serving", RENEWAL, "inner:renewal-ok" } } do
    local x = G:run(PRELUDE .. c[2], { mounts = { ["images/git/sshd-identity.sh"] = "/usr/local/bin/sshd-identity.sh" } })
    T:arm(c[1], text.contains("\n" .. x.out, "\n" .. c[3] .. "\n"), x.why)
end
T:finish()
