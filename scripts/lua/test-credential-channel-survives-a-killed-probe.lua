-- @env PATH HOME
-- @trace spec:ci-release, order:1347-r9g8, order:1903-djsq, order:2378-hcxg
--
-- test-credential-channel-survives-a-killed-probe.lua — check-credential-channel.sh answers, once,
-- when a probe hangs or dies: a silent guard reads downstream as "not blocked". Ported from the .sh
-- of the same name (2378-hcxg), which ran in this checkout and skipped an arm when its git directory
-- held a credential store; this runs in a scratch repository.
--
--   1 a hanging busctl    2 a busctl killed by a signal is never "missing", and is named unprobed
--   3 a hanging gh        4 one emitting line per verdict, and the counter can move
--   1, 3 and the exact string in 2 need timeout(1) or gtimeout(1): a named skip without
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-channel-survives-a-killed-probe.lua
-- Verdict: ok:credential-channel-survives-a-killed-probe:<n> arms | violation:...

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("credential-channel-survives-a-killed-probe")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = "scripts/check-credential-channel.sh"
local BOUND = fixture.which("timeout") and "timeout" or fixture.which("gtimeout") and "gtimeout" or ""
local function run(busctl, gh)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/home"); fs.mkdir(d.rel .. "/repo")
    fs.write(d.rel .. "/bin/busctl", "#!/usr/bin/env bash\n" .. busctl)
    fs.write(d.rel .. "/bin/gh", "#!/usr/bin/env bash\n" .. gh)
    T:must{ "chmod", "+x", d.abs .. "/bin/busctl", d.abs .. "/bin/gh" }
    local t0 = time.now_ms()
    -- The guard ABANDONS a hung client instead of killing it, so its output goes to files (a pipe
    -- would wait for the child) and the stubs leave their pids to be reaped here.
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT .. "/" .. GUARD, BOUND }, cwd = d.abs, env = bus.env{ HOME = d.abs .. "/home" }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000, stdin = [==[
D="$1"; export GIT_CONFIG_NOSYSTEM=1 TILLANDSIAS_CCC_NO_LANE=1 PATH="$1/bin:$PATH" FIXTURE_PIDS="$1/pids"; unset GH_TOKEN GITHUB_TOKEN GIT_DIR GIT_WORK_TREE
cd "$D/repo" && git init -q && git config core.hooksPath .git/hooks && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m x || exit 90
rc=0; if [ -n "$3" ]; then "$3" 90 bash "$2" >"$D/out" 2>"$D/err" </dev/null || rc=$?; else bash "$2" >"$D/out" 2>"$D/err" </dev/null || rc=$?; fi
[ ! -f "$D/pids" ] || while read -r p; do kill -KILL "$p" 2>/dev/null; done <"$D/pids"
exit 0
]==] }
    local o = r.code == 0 and fs.exists(d.rel .. "/out") and fs.read(d.rel .. "/out") or ""
    local n, v = 0, ""
    for l in o:gmatch("[^\r\n]+") do
        if l:match("^(%a+):[a-z0-9:-]+$") and (l:match("^ok:") or l:match("^unverified:") or l:match("^blocked:") or l:match("^missing:") or l:match("^unknown:")) then n, v = n + 1, l end
    end
    return { s = (time.now_ms() - t0) / 1000, n = n, v = v, why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300) .. (r.stderr or ""):sub(1, 200) }
end
local HANG = 'echo $$ >>"$FIXTURE_PIDS"\nexec sleep 3600\n'
local x
if BOUND == "" then
    out.line("skip: 1 3 no timeout(1) or gtimeout(1): they hang a probe on purpose")
else
    x = run(HANG, "exit 0\n")
    T:arm("1a a hanging busctl does not hang the guard", x.s < 60, x.s .. " s")
    T:arm("1b and there is one verdict", x.n == 1, x.why)
end
-- gh answers nothing here: one that said yes would be the guard's evidence, not the dead probe.
x = run("kill -9 $$\n", "exit 1\n")
T:arm("2a a killed busctl leaves one verdict", x.n == 1, x.why)
T:arm("2b and is never reported as missing", x.v ~= "" and not x.v:match("^missing:"), x.why)
if BOUND ~= "" then T:arm("2c it is named unprobed", x.v == "unknown:secret-service-unprobed", x.why) end
if BOUND ~= "" then
    x = run('echo "NAME PID"\necho "org.freedesktop.secrets 1 gnome-keyring"\nexit 0\n', HANG)
    T:arm("3a a hanging gh does not hang the guard", x.s < 80, x.s .. " s")
    T:arm("3b and there is one verdict", x.n == 1, x.why)
end
local src = fs.read(GUARD):gsub("\r", "")
local function emitters(body, v)
    local n = 0
    for l in (body .. "\n"):gmatch("([^\n]*)\n") do
        if l:match("^%s*(.*)$"):sub(1, #v + 6) == 'echo "' .. v then n = n + 1 end
    end
    return n
end
for _, v in ipairs{ "missing:no-credential-channel", "unknown:secret-service-unprobed" } do
    T:arm("4a " .. v .. " has one emitting line", emitters(src, v) == 1, tostring(emitters(src, v)))
    T:arm("4b CONTROL a second one moves the count", emitters(src .. '\nsecond() {\n  echo "' .. v .. '"\n}\n', v) == 2, "unmoved")
end
T:finish()
