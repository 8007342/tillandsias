-- @env PATH HOME
-- @trace spec:git-mirror-service, order:749-2fqj, order:2373-8vq6
--
-- test-mirror-receive-wrapper.lua — tillandsias-receive.sh takes a push into the one FIXED
-- repository whatever path the client names, with the audit variables from its certificate; and the
-- receive hardening reaches an existing volume. Ported from the .sh of the same name (2373-8vq6).
--
--   1 the four TILLANDSIAS_PUSH_* come from the certificate, the path from the server
--   2 a non-receive verb, no auth info, a plain key and no project: refused by name
--   3 a force push and a deletion are refused on an UPGRADED volume
--   4 fsckObjects is the deciding control there: a copy without it accepts the malformed commit
--   5 M5, in the real image over sshd: project B's path lands in project A and B is never made
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-receive-wrapper.lua
-- Verdict: ok:mirror-receive-wrapper:<n> arms | violation:... (5 is a named skip with no podman)

local fixture = require "common.fixture"
local T = fixture.new("mirror-receive-wrapper")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local MID, WRAP = "fixt0mirror0id0abcd", ROOT .. "/images/git/tillandsias-receive.sh"
if not fixture.which("ssh-keygen") then T:skip("no-ssh-keygen") end
local w = T:scratch()
local BASE = { PATH = env.get("PATH"), HOME = w.abs, GIT_CONFIG_NOSYSTEM = "1", GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid", GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid", LANGUAGE = "en" }
local function sh(body, more, ...)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", w.abs, ... }, cwd = w.abs, stdin = 'W="$1"\n' .. body, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return { rc = r.code, out = "\n" .. o, why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 500) }
end
local function setup(what, x)
    if x.rc ~= 0 then T:refuse("setup-failed", what .. " " .. x.why) end
    return x
end
-- SSH_USER_AUTH as sshd's ExposeAuthInfo writes it: `publickey <cert-type> <base64>`.
local s = setup("certificate", sh([==[
set -e
ssh-keygen -q -N '' -t ed25519 -f "$W/client_ca"; ssh-keygen -q -N '' -t ed25519 -f "$W/key"
ssh-keygen -q -s "$W/client_ca" -I token-fixture-keyid -n "til:forge-push:$2" -z 42 "$W/key.pub"
printf 'publickey %s\n' "$(cat "$W/key-cert.pub")" >"$W/auth-info"
read -r kind plain rest <"$W/key.pub"; printf 'publickey ssh-ed25519 %s\n' "$plain" >"$W/plain-auth"
mkdir -p "$W/root/projecta"; git init -q --bare "$W/root/projecta"
cat >"$W/recorder" <<REC
#!/bin/sh
{ echo "argv1=\$1"; echo "fp=\$TILLANDSIAS_PUSH_KEY_FP"; echo "principal=\$TILLANDSIAS_PUSH_PRINCIPAL"
  echo "serial=\$TILLANDSIAS_PUSH_SERIAL"; echo "keyid=\$TILLANDSIAS_PUSH_KEY_ID"; } >"$W/record"
REC
chmod +x "$W/recorder"; ssh-keygen -l -f "$W/key-cert.pub"
]==], nil, MID))
local fp = s.out:match("(SHA256:%S+)") or "?"
local function receive(more)
    local e = { TILLANDSIAS_RECEIVE_ROOT = w.abs .. "/root", TILLANDSIAS_RECEIVE_PROJECT = "projecta", TILLANDSIAS_GIT_RECEIVE_PACK = "/bin/false", SSH_USER_AUTH = w.abs .. "/auth-info", SSH_ORIGINAL_COMMAND = "git-receive-pack 'x'" }
    for k, v in pairs(more) do e[k] = v end
    -- The door takes no SSH_* name, so the shell sets them.
    local pre = ""
    for k, v in pairs(e) do
        if v ~= "" or k == "TILLANDSIAS_RECEIVE_PROJECT" then pre = pre .. "export " .. k .. "='" .. v:gsub("'", "'\\''") .. "'\n" end
    end
    return sh("unset SSH_USER_AUTH SSH_ORIGINAL_COMMAND\n" .. pre .. 'exec sh "$2" </dev/null\n', nil, WRAP)
end
local x = receive{ SSH_ORIGINAL_COMMAND = "git-receive-pack '/projectB'", TILLANDSIAS_GIT_RECEIVE_PACK = w.abs .. "/recorder" }
local record = fs.exists(w.rel .. "/record") and fs.read(w.rel .. "/record") or ""
local want = "argv1=" .. w.abs .. "/root/projecta\nfp=" .. fp .. "\nprincipal=til:forge-push:" .. MID .. "\nserial=42\nkeyid=token-fixture-keyid\n"
T:arm("1 the fixed path and the certificate's own values reach receive-pack", x.rc == 0 and record == want, x.why .. " [" .. record .. "] want [" .. want .. "]")
for _, c in ipairs{ { "a non-receive verb", { SSH_ORIGINAL_COMMAND = "ls -la" }, "not-receive-pack" }, { "no auth info", { SSH_USER_AUTH = "" }, "no-auth-info" },
    { "a plain key", { SSH_USER_AUTH = w.abs .. "/plain-auth" }, "no-cert-in-auth-info" }, { "no project", { TILLANDSIAS_RECEIVE_PROJECT = "" }, "no-project" } } do
    x = receive(c[2])
    T:arm("2 " .. c[1] .. " is refused as " .. c[3], x.rc ~= nil and x.rc ~= 0 and text.contains(x.out, "\nfail:tillandsias-receive:" .. c[3] .. "\n"), x.why)
end

-- A volume born permissive, upgraded by the real entrypoint's setup-only seam, its hooks made inert:
-- receive CONFIG is the subject here.
setup("upgraded volume", sh([==[
set -e
M="$W/vol/project"; C="$W/client"; mkdir -p "$W/vol"; git init -q --bare "$M"
for k in denyNonFastForwards denyDeletes fsckObjects; do git -C "$M" config "receive.$k" false; done
git init -q "$C"; echo base >"$C/file"; git -C "$C" add file; git -C "$C" commit -qm base; git -C "$C" branch -M main
git -C "$C" push -q "$M" main
PROJECT=project TILLANDSIAS_GIT_SERVICE_ROOT="$W/vol" TILLANDSIAS_GIT_SERVICE_SHARE="$2/images/git" TILLANDSIAS_GIT_SERVICE_SETUP_ONLY=1 \
    TILLANDSIAS_PROJECT_DEFAULT_BRANCH=main bash "$2/images/git/entrypoint.sh" </dev/null
for h in pre-receive post-receive; do printf '#!/bin/sh\nexit 0\n' >"$M/hooks/$h"; chmod +x "$M/hooks/$h"; done
]==], nil, ROOT))
x = sh('git -C "$W/vol/project" config --get receive.fsckObjects; git -C "$W/vol/project" config --get receive.denyNonFastForwards')
T:arm("3a the hardening reached the existing volume", x.out == "\ntrue\ntrue\n", x.why)
x = sh('git -C "$W/client" commit -q --amend -m rewritten && git -C "$W/client" push -q --force "$W/vol/project" main')
T:arm("3b a force push is refused, for that cause", x.rc ~= 0 and x.out:lower():find("non%-fast%-forward") ~= nil, x.why)
x = sh('git -C "$W/client" push -q "$W/vol/project" :main')
local low = x.out:lower()
T:arm("3c so is a deletion", x.rc ~= 0 and (low:find("deny deleting", 1, true) or low:find("denying ref deletion", 1, true) or low:find("deletion.*denied")) ~= nil, x.why)
setup("malformed commit", sh([==[
set -e
tree="$(git -C "$W/client" rev-parse 'HEAD^{tree}')"
bad="$(printf 'tree %s\nauthor fixture <f@example.invalid> 1700000000 +0000\ncommitter broken 1700000000 +0000\n\nbad\n' "$tree" | git -C "$W/client" hash-object -t commit --literally -w --stdin)"
git -C "$W/client" update-ref refs/heads/evil "$bad"
]==]))
x = sh('git -C "$W/client" push -q "$W/vol/project" refs/heads/evil')
local y = sh('git -C "$W/vol/project" rev-parse --quiet --verify refs/heads/evil')
low = x.out:lower()
T:arm("4a a malformed commit is refused and no ref is made", x.rc ~= 0 and (low:find("missingemail", 1, true) or low:find("fsck", 1, true) or low:find("invalid committer", 1, true)) ~= nil and y.rc ~= 0, x.why .. y.why)
x = sh('cp -a "$W/vol/project" "$W/permissive.git" && git -C "$W/permissive.git" config receive.fsckObjects false && git -C "$W/client" push -q "$W/permissive.git" refs/heads/evil')
T:arm("4b CONTROL a copy with fsckObjects off accepts it", x.rc == 0, x.why)

local M5 = [==[
set -u
export TILLANDSIAS_MIRROR_ID=fixt0mirror0id0abcd
mkdir -p /tmp/fx/ca /tmp/fx/client /tmp/fx/srv
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/host_ca
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/ca/client_ca
cat > /tmp/fx/signer.sh <<'SEOF'
#!/bin/bash
pub="$1"; principal="$2"
d=$(mktemp -d); cp "$pub" "$d/k.pub"
ssh-keygen -q -s /tmp/fx/ca/host_ca -I fixture-host -h -n "$principal" -z 7 "$d/k.pub" || exit 1
cat "$d/k-cert.pub"
SEOF
chmod +x /tmp/fx/signer.sh
export TILLANDSIAS_SSH_SIGNER_CMD=/tmp/fx/signer.sh
export TILLANDSIAS_TRUSTED_USER_CA_FILE=/tmp/fx/ca/client_ca.pub
export TILLANDSIAS_RECEIVE_PROJECT=projecta
export TILLANDSIAS_RECEIVE_ROOT=/tmp/fx/srv
git init -q --bare /tmp/fx/srv/projecta
git -C /tmp/fx/srv/projecta symbolic-ref HEAD refs/heads/main
printf "#!/bin/sh\nprintenv | grep ^TILLANDSIAS_PUSH_ > /tmp/fx/receive-env\nexit 0\n" > /tmp/fx/srv/projecta/hooks/pre-receive
chmod +x /tmp/fx/srv/projecta/hooks/pre-receive
/usr/local/bin/sshd-identity.sh ensure | grep -q ok:sshd-identity:ready || { echo inner:ensure-failed; sed -n "1,8p" /tmp/tillandsias-sshd/sshd.err >&2; exit 90; }
grep -q "SetEnv .*TILLANDSIAS_RECEIVE_PROJECT=projecta" /tmp/tillandsias-sshd/sshd_config || { echo inner:setenv-not-rendered; exit 95; }
ssh-keygen -q -N "" -t ed25519 -f /tmp/fx/client/key
ssh-keygen -q -s /tmp/fx/ca/client_ca -I token-m5-keyid -n "til:forge-push:fixt0mirror0id0abcd" -z 99 /tmp/fx/client/key.pub
printf "@cert-authority git-fixt0mirror0id0abcd %s\n" "$(cat /tmp/fx/ca/host_ca.pub)" > /tmp/fx/kh
export HOME=/tmp/fx/client
git config --global user.email f@example.invalid
git config --global user.name fixture
git init -q /tmp/fx/client/repo
cd /tmp/fx/client/repo
echo m5 > file && git add file && git commit -qm m5 && git branch -M main
WANT_SHA="$(git rev-parse HEAD)"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/fx/kh -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o HostKeyAlias=git-fixt0mirror0id0abcd -i /tmp/fx/client/key -p 2222"
git push -q ssh://git@127.0.0.1:2222/projectB main 2>/tmp/fx/push.err || { echo inner:push-failed; sed -n "1,8p" /tmp/fx/push.err >&2; exit 91; }
GOT_SHA="$(git -C /tmp/fx/srv/projecta rev-parse refs/heads/main 2>/dev/null || echo none)"
[ "$GOT_SHA" = "$WANT_SHA" ] || { echo "inner:landed-wrong:got=$GOT_SHA want=$WANT_SHA"; exit 92; }
[ -d /tmp/fx/srv/projectB ] && { echo inner:projectB-created; exit 93; }
grep -q "^TILLANDSIAS_PUSH_PRINCIPAL=til:forge-push:fixt0mirror0id0abcd$" /tmp/fx/receive-env || { echo inner:hook-missing-principal; cat /tmp/fx/receive-env >&2; exit 94; }
grep -q "^TILLANDSIAS_PUSH_SERIAL=99$" /tmp/fx/receive-env || { echo inner:hook-missing-serial; exit 96; }
grep -q "^TILLANDSIAS_PUSH_KEY_ID=token-m5-keyid$" /tmp/fx/receive-env || { echo inner:hook-missing-keyid; exit 97; }
grep -q "^TILLANDSIAS_PUSH_KEY_FP=SHA256:" /tmp/fx/receive-env || { echo inner:hook-missing-fp; exit 98; }
echo inner:m5-fixed-path-ok
]==]
if not fixture.which("podman") then
    out.line("skip: 5 no podman here")
else
    x = require("common.gitimage").new(T):run(M5, { mounts = { ["images/git/sshd-identity.sh"] = "/usr/local/bin/sshd-identity.sh", ["images/git/tillandsias-receive.sh"] = "/usr/local/bin/tillandsias-receive" } })
    T:arm("5 M5 a push naming project B lands in the fixed repository", text.contains("\n" .. x.out, "\ninner:m5-fixed-path-ok\n"), x.why)
end
T:finish()
