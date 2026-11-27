-- @env PATH HOME
-- @trace order:1456-ib6i, order:2377-znx4
--
-- test-credential-channel-host-push-lane.lua — check-credential-channel.sh counts a wired host-push
-- lane as a push path when the keyring cannot answer, and only then. Ported from the .sh of the same
-- name (2377-znx4). The shipped functions, cut from the script, with the keyring, sshd and mirror
-- replaced; the .sh's two arms that read a live lane and a live mirror are scratch ones here.
--
--   1 a wired lane is a push path       2 no lane, 3 no sshd: the keyring refusal stands
--   4 a verified keyring answers        5 a forge never consults the lane
--   6 the real banner read sees a listener (named skip with nothing to listen with) and no listener
--   7 upstream refuses, 8 upstream stale: not a push path
--   9 the real reader takes the newest verdict from a mirror     10 a broken mirror is not one
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-channel-host-push-lane.lua
-- Verdict: ok:credential-channel-host-push-lane:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("credential-channel-host-push-lane")
local SH = fixture.posix_shell()
local src, funcs = "\n" .. fs.read("scripts/check-credential-channel.sh"):gsub("\r", ""), {}
for _, f in ipairs{ "_ccc_timeout", "_ccc_lane_banner", "_ccc_host_push_lane", "_ccc_verdict_with_lane", "forge_upstream_auth_verdict", "_afford", "_ccc_relay_state" } do
    local body = src:match("\n(" .. f .. "%(%) {\n.-\n})\n") or src:match("\n(" .. f .. "%(%) {[^\n]*})\n")
    if not body then T:refuse("function-not-found", f) end
    funcs[#funcs + 1] = body
end
local w = T:scratch()
fs.mkdir(w.rel .. "/lane")
fs.write(w.rel .. "/lane/known_hosts", "@cert-authority git-v0test ssh-ed25519 AAAA\n")
fs.write(w.rel .. "/lane/testhost.ed25519", ""); fs.write(w.rel .. "/lane/testhost.approle.json", "")
local PRE = table.concat(funcs, "\n") .. [==[

W="$1"
export TILLANDSIAS_HOST_PUSH_HOST=testhost TILLANDSIAS_HOST_PUSH_DIR="$W/lane"
keyring() { eval "credential_channel_verdict() { echo '$1'; return $2; }"; }
sshd_up() { _ccc_lane_banner() { printf 'SSH-2.0'; }; }
sshd_silent() { _ccc_lane_banner() { return 1; }; }
upstream() { eval "forge_upstream_auth_verdict() { echo '$1'; return $2; }"; }
relay() { eval "_ccc_relay_state() { echo '$1'; }"; }
ask() { _ccc_verdict_with_lane 2>"$W/err"; }
relay ok/none/0
]==]
local LOCKED = "keyring unknown:secret-service-unprobed 1; sshd_up; upstream ok:forge-git-mirror 0\n"
local function sh(body)
    local r = proc.run{ argv = { SH, "-s", "--", w.abs }, cwd = w.abs, stdin = PRE .. body, env = { PATH = env.get("PATH"), HOME = w.abs, GIT_CONFIG_NOSYSTEM = "1" }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = text.trim((r.stdout or ""):gsub("\r", ""))
    local err = fs.exists(w.rel .. "/err") and fs.read(w.rel .. "/err") or ""
    return { rc = r.code, out = o, err = err, why = "rc=" .. tostring(r.code) .. " [" .. o:sub(1, 300) .. "] " .. err:sub(1, 300) .. (r.stderr or ""):sub(1, 200) }
end
local function is(x, rc, out_) return x.rc == rc and x.out == out_ end
local LANE, REFUSED = "ok:host-push-lane:git-v0test", "unknown:secret-service-unprobed"
local x = sh(LOCKED .. "ask")
T:arm("1 a wired lane is a push path, the keyring's verdict kept on stderr", is(x, 0, LANE) and text.contains(x.err, "keyring path: " .. REFUSED), x.why)
x = sh(LOCKED .. 'TILLANDSIAS_HOST_PUSH_DIR="$W/nowhere" ask')
T:arm("2 CONTROL with no lane the keyring refusal stands", is(x, 1, REFUSED), x.why)
x = sh(LOCKED .. "sshd_silent; ask")
T:arm("3 lane files without a listening sshd are not a push path", is(x, 1, REFUSED), x.why)
x = sh("keyring ok:gh-keyring-push-verified 0; sshd_up; ask")
T:arm("4 a verified keyring answers for itself", is(x, 0, "ok:gh-keyring-push-verified"), x.why)
x = sh(LOCKED .. "TILLANDSIAS_HOST_KIND=forge ask")
T:arm("5 a forge never consults the host lane", x.rc == 1, x.why)
x = sh([==[
p=0; for t in socat ncat nc; do command -v "$t" >/dev/null 2>&1 && { p="$t"; break; }; done
[ "$p" != 0 ] || { echo none; exit 0; }
port=$((20000 + $$ % 20000)); printf 'SSH-2.0-fixture\r\n' >"$W/banner"
case "$p" in socat) socat TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr OPEN:"$W/banner" >/dev/null 2>&1 & ;; ncat) ncat -l 127.0.0.1 $port <"$W/banner" >/dev/null 2>&1 & ;; *) nc -l 127.0.0.1 $port <"$W/banner" >/dev/null 2>&1 & ;; esac
l=$!; sleep 1; b="$(_ccc_lane_banner $port)"; kill "$l" 2>/dev/null; wait "$l" 2>/dev/null; echo "banner=$b"
]==])
if x.out == "none" then out.line("skip: 6a nothing here can listen")
else T:arm("6a the real banner read sees a listener", x.out == "banner=SSH-2.0", x.why) end
x = sh("_ccc_lane_banner 1; echo rc=$?")
T:arm("6b and answers nothing where none listens", x.out ~= "rc=0" and x.out:match("^rc=%d+$") ~= nil, x.why)
x = sh(LOCKED .. "upstream blocked:upstream-push-unauthorized 1; ask")
T:arm("7 a lane whose upstream refuses is not a push path", is(x, 1, "blocked:upstream-push-unauthorized"), x.why)
x = sh(LOCKED .. "upstream blocked:upstream-auth-stale 1; ask")
T:arm("8 a stale upstream verdict refuses, by name", is(x, 1, "blocked:upstream-auth-stale"), x.why)
local MIRROR = [==[
git init -q --bare "$W/m.git"; b="$(git -C "$W/m.git" hash-object -w --stdin </dev/null)"; now="$(date +%s)"
for v in VERDICTS; do git -C "$W/m.git" update-ref "refs/tillandsias/upstream-auth/$v" "$b"; done
forge_upstream_auth_verdict "$W/m.git" 2>"$W/err"; rc=$?; rm -r "$W/m.git"; exit $rc
]==]
for _, c in ipairs{ { "authorized/$now denied/permission/$((now - 60))", 0, "ok:forge-git-mirror" }, { "denied/permission/$now authorized/$((now - 60))", 1, "blocked:upstream-push-unauthorized" }, { "authorized/$((now - 99999))", 1, "blocked:upstream-auth-stale" } } do
    x = sh((MIRROR:gsub("VERDICTS", function() return c[1] end)))
    T:arm("9 the real reader answers " .. c[3], is(x, c[2], c[3]), x.why)
end
x = sh(LOCKED .. "relay broken/credential/1; ask")
T:arm("10a a broken mirror is not a push path, with the remedy", is(x, 1, "blocked:mirror-broken:credential") and text.contains(x.err, "  remedy: the operator re-seeds"), x.why)
x = sh(LOCKED .. "ask")
T:arm("10b an ok tick restores the lane", is(x, 0, LANE), x.why)
T:finish()
