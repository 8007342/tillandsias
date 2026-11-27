-- @trace order:1164-cftu, order:2205-cepb
-- @env TILLANDSIAS_LAND_UNDER_TEST
-- @env PATH
--
-- test-land-auth-retry.lua — PORTED from test-land-auth-retry.sh (2205-cepb),
-- same arms, same lines. Pins the land tool's ONE retry on the auth
-- signature: a push that fails with "Authentication failed" once and succeeds
-- on the retry lands; two failures refuse exactly as before (exit 5, the
-- 1025-a896 text); and no gh auth command is ever run. Hermetic: a scratch
-- bare origin, a scratch checkout carrying a copy of the land tool, a green
-- stub gate, a `git` wrapper on PATH that fails the first N pushes with the
-- auth signature and delegates everything else to the real git, and a `gh`
-- stub that records every call. Scratch lives under target/plan-scratch.
-- TILLANDSIAS_LAND_UNDER_TEST overrides the tool under test (mutation control).
--
-- Verdict: ok:land-auth-retry-fixture:all | violation:land-auth-retry-fixture:<n>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local LANDSH = env.get("TILLANDSIAS_LAND_UNDER_TEST") or (root .. "/scripts/land-on-platform-branch.sh")
local PATH = env.get("PATH") or "/usr/bin:/bin"

local REAL_GIT
for dir in PATH:gmatch("[^:]+") do
    if not REAL_GIT and proc.run{ argv = { "test", "-x", dir .. "/git" } }.ok then REAL_GIT = dir .. "/git" end
end
if not REAL_GIT then verdict.could_not_run("land-auth-retry-fixture:no-git") end

local passes, fails = 0, 0
local function ok(m) passes = passes + 1; out.line("ok: " .. m) end
local function bad(m) fails = fails + 1; out.line("FAIL: " .. m) end

local seq = 0
local function g(d, args)
    local a = { REAL_GIT, "-C", d, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, timeout_ms = 60000 }
end

local function scratch(n)
    seq = seq + 1
    local rel = "target/plan-scratch/land-auth-retry-" .. tostring(time.now_ms()) .. "-" .. seq
    local d = root .. "/" .. rel
    proc.run{ argv = { "mkdir", "-p", d .. "/w/scripts", d .. "/bin" } }
    proc.run{ argv = { REAL_GIT, "init", "-q", "--bare", d .. "/origin.git" } }
    proc.run{ argv = { REAL_GIT, "init", "-q", "-b", "linux-next", d .. "/w" } }
    g(d .. "/w", { "remote", "add", "origin", d .. "/origin.git" })
    proc.run{ argv = { "cp", LANDSH, d .. "/w/scripts/land-on-platform-branch.sh" } }
    fs.write(rel .. "/w/build.sh", "#!/usr/bin/env bash\nexit 0\n")
    proc.run{ argv = { "chmod", "+x", d .. "/w/build.sh" } }
    g(d .. "/w", { "add", "-A" })
    g(d .. "/w", { "commit", "-q", "-m", "base" })
    g(d .. "/w", { "push", "-q", "origin", "linux-next" })
    g(d .. "/w", { "commit", "-q", "--allow-empty", "-m", "unpushed" })
    fs.write(rel .. "/auth-failures-left", n .. "\n")
    -- git wrapper: fail the first N pushes with the auth signature, then delegate.
    fs.write(rel .. "/bin/git", ([[#!/usr/bin/env bash
if [ "${1:-}" = "push" ]; then
    left=$(cat "@D@/auth-failures-left")
    if [ "$left" -gt 0 ]; then
        echo $((left - 1)) > "@D@/auth-failures-left"
        if [ -e "@D@/french" ] && [ "${LANGUAGE:-}" != en ]; then
            echo "fatal : Échec d'authentification pour 'https://github.com/example/repo.git/'" >&2
        else
            echo "fatal: Authentication failed for 'https://github.com/example/repo.git/'" >&2
        fi
        exit 128
    fi
fi
exec "@GIT@" "$@"
]]):gsub("@D@", function() return d end):gsub("@GIT@", function() return REAL_GIT end))
    fs.write(rel .. "/bin/gh", '#!/usr/bin/env bash\necho "gh $*" >> "' .. d .. '/gh-calls"; exit 1\n')
    proc.run{ argv = { "chmod", "+x", d .. "/bin/git", d .. "/bin/gh" } }
    fs.write(rel .. "/gh-calls", "")
    return d, rel
end

local function run_land(d)
    return proc.run{ argv = { "bash", "scripts/land-on-platform-branch.sh", "linux-next", "1" },
        cwd = d .. "/w", stdin = "", timeout_ms = 300000,
        env = { PATH = d .. "/bin:" .. PATH, GIT_TERMINAL_PROMPT = "0", TILLANDSIAS_LAND_AUTH_RETRY_DELAY = "0" } }
end
local function has_line_prefix(s, p)
    for _, l in ipairs(text.lines(s)) do if l:sub(1, #p) == p then return true end end
    return false
end
local function count_lines_with(s, p)
    local n = 0
    for _, l in ipairs(text.lines(s)) do if l:find(p, 1, true) then n = n + 1 end end
    return n
end
local function tail2(s)
    local ls = text.lines(s)
    local t = {}
    for i = math.max(1, #ls - 1), #ls do t[#t + 1] = ls[i] .. " " end
    return table.concat(t)
end
local function cleanup(d) proc.run{ argv = { "find", d, "-delete" }, timeout_ms = 60000 } end

-- ARM 1: one auth failure, then success -> lands, and the retry is visible.
local d, rel = scratch(1)
local r = run_land(d)
local o, e, rc = r.stdout or "", r.stderr or "", r.code
local calls = fs.read(rel .. "/gh-calls") or ""
if has_line_prefix(o, "ok:land:") then ok("one auth failure then success lands (rc=" .. tostring(rc) .. ")")
else bad("did not land after one auth failure: rc=" .. tostring(rc) .. " " .. tail2(e)) end
if o:find("auth-failed once, retrying after 0s (1164-cftu)", 1, true) then ok("the retry is named in the land output")
else bad("no retry line") end
if calls == "" then ok("no gh command was run on the retry path") else bad("gh was invoked: " .. calls) end
cleanup(d)

-- ARM 2 (NEGATIVE CONTROL): two auth failures -> refuses exactly as before.
d, rel = scratch(2)
r = run_land(d)
o, e, rc = r.stdout or "", r.stderr or "", r.code
calls = fs.read(rel .. "/gh-calls") or ""
if rc == 5 then ok("two auth failures refuse with exit 5") else bad("rc=" .. tostring(rc) .. ", wanted 5") end
if e:find("refused:land:auth-failed", 1, true) then ok("the refusal verdict is unchanged")
else bad("no refused:land:auth-failed") end
if e:find("do NOT run 'gh auth login' or 'gh auth refresh'", 1, true) then ok("the 1025-a896 text is unchanged")
else bad("1025-a896 text missing") end
if count_lines_with(o, "auth-failed once, retrying") == 1 then ok("exactly one retry before refusing")
else bad("retry count wrong") end
if calls == "" then ok("NEGATIVE CONTROL: no gh command even when refusing") else bad("gh was invoked while refusing") end
cleanup(d)

-- ARM 3 (2281-amjg): a git that speaks French unless told LANGUAGE=en is still
-- read as the auth signature: retried once, lands.
d, rel = scratch(1)
fs.write(rel .. "/french", "")
r = run_land(d)
if has_line_prefix(r.stdout or "", "ok:land:") and (r.stdout or ""):find("auth-failed once, retrying", 1, true) then
    ok("a French git's auth failure is retried and lands")
else bad("French git: rc=" .. tostring(r.code) .. " " .. tail2(r.stderr or "")) end
cleanup(d)

out.line("land-auth-retry fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:land-auth-retry-fixture:all", 0) end
verdict.emit("violation:land-auth-retry-fixture:" .. fails, 1)
