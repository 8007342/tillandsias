-- @env PATH HOME
-- @trace order:1827-3rj4, order:2373-8vq6
--
-- test-mirror-coordinator-bump.lua — after a push the mirror's post-receive hook sends the fleet
-- coordinator ONE bump with the Access service token from vault, and a down or unconfigured
-- coordinator never affects the push. Ported from the .sh of the same name (2373-8vq6). This checkout's
-- hook in the git-mirror image, --network none: a bare repo, a stub vault-cli, a socat coordinator.
--
--   1 up: one POST with the bump body and the token headers, one log line
--   2 down: the push lands and one line says unreachable   3 unconfigured: it lands and says so
--   4 the token is in no log, up or down
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-coordinator-bump.lua
-- Verdict: ok:mirror-coordinator-bump:<n> arms | violation:... | skip:...:no-podman

local fixture = require "common.fixture"
local gitimage = require "common.gitimage"
local T = fixture.new("mirror-coordinator-bump")
local G = gitimage.new(T)
local INNER = [==[
#!/bin/sh
# Inside the git-mirror image. $1 = case: up | down | unconfigured
set -u
CASE="$1"
SECRET="s3cr3t-coord-token-$$"
mkdir -p /w/bin && cd /w || exit 2
cat > /w/bin/vault-cli <<VC
#!/bin/sh
[ "$CASE" = unconfigured ] && exit 2
case "\$*" in
  *-field=client_id*) echo "client-id-for-test" ;;
  *-field=client_secret*) echo "$SECRET" ;;
  *-field=url*) echo "http://127.0.0.1:18787" ;;
  *) exit 4 ;;
esac
VC
chmod 755 /w/bin/vault-cli
export PATH="/w/bin:$PATH" HOME=/w
git config --global user.email t@t.invalid; git config --global user.name t; git config --global init.defaultBranch main
git init -q --bare /w/mirror.git
git -C /w/mirror.git remote add origin https://github.com/Owner/Repo.git
cp /hook/post-receive /w/mirror.git/hooks/post-receive && chmod 755 /w/mirror.git/hooks/post-receive
git clone -q /w/mirror.git /w/clone 2>/dev/null
if [ "$CASE" = up ]; then
  # Every request is appended whole to request.txt; each gets a bare 200.
  cat > /w/respond.sh <<'RS'
#!/bin/sh
timeout 1 cat >> /w/request.txt
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}'
sleep 0.5
RS
  chmod 755 /w/respond.sh
  socat TCP-LISTEN:18787,bind=127.0.0.1,reuseaddr,fork EXEC:/w/respond.sh &
  sleep 0.5
fi
cd /w/clone && echo one > f && git add f && git commit -q -m one
git push -q origin main > /w/push.out 2>&1; echo "push_rc=$?"
sleep 3
echo "head=$(git -C /w/mirror.git rev-parse HEAD)"
echo "--- log"
cat /tmp/git-push.log $HOME/.cache/tillandsias/git-push.log /var/log/tillandsias/git-push.log 2>/dev/null | grep 'coordinator:'
echo "--- request"
[ -f /w/request.txt ] && tr -d '\r' < /w/request.txt
echo "--- leak"
if cat /w/push.out /tmp/git-push.log $HOME/.cache/tillandsias/git-push.log /var/log/tillandsias/git-push.log 2>/dev/null | grep -q "$SECRET"; then echo leaked; else echo clean; fi
]==]
local POSTURE = { "--network", "none", "--tmpfs", "/w:rw,exec,mode=1777", "--tmpfs", "/tmp:rw,mode=1777" }
local function case(name)
    local x = G:run(INNER, { posture = POSTURE, shell = "sh", args = { name }, mounts = { ["images/git/post-receive-hook.sh"] = "/hook/post-receive" } })
    x.out = "\n" .. x.out
    return x
end
local function count(s, pattern) return select(2, s:gsub(pattern, "")) end
local up, down, un = case("up"), case("down"), case("unconfigured")
local head = up.out:match("\nhead=(%x+)") or "?"
local req = "\n" .. (up.out:match("\n%-%-%- request\n(.*)%-%-%- leak\n") or "") .. "\n"
T:arm("1a up: the push lands", text.contains(up.out, "\npush_rc=0\n"), up.why)
T:arm("1b exactly one POST /v1/op", count(req, "\nPOST /v1/op ") == 1, req:sub(1, 500))
T:arm("1c its body is the bump for owner/repo at the new head", text.contains(req, '"op":"bump","ns":"owner/repo","head_sha":"' .. head .. '"'), req:sub(1, 500))
local low = req:lower()
T:arm("1d it carries the service token headers", text.contains(low, "\ncf-access-client-id: client-id-for-test\n") and text.contains(low, "\ncf-access-client-secret: s3cr3t-coord-token-"), "headers missing")
T:arm("1e one log line says bumped", text.contains(up.out, "coordinator: bumped owner/repo head="), up.why)
T:arm("2 down: the push lands and one line says unreachable", text.contains(down.out, "\npush_rc=0\n") and count(down.out, "coordinator: unreachable") == 1, down.why)
T:arm("3 unconfigured: the push lands and one line says so", text.contains(un.out, "\npush_rc=0\n") and count(un.out, "coordinator: not configured") == 1, un.why)
T:arm("4 the token is in no log", text.contains(up.out, "\nclean\n") and text.contains(down.out, "\nclean\n"), "leaked")
T:finish()
