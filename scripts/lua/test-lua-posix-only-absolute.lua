-- @env PATH HOME
-- @trace order:2402-isab
--
-- test-lua-posix-only-absolute.lua — check-lua-posix-only-absolute.lua refuses a first-character
-- absoluteness test and nothing else.
--
--   1 `p:sub(1, 1) ~= "/"` is refused, by line      2 the same with other spacing
--   3 CONTROL the same line accepting `%a:` passes    4 CONTROL fixture.is_abs passes
--   5 CONTROL an `== "/"` test passes                 6 CONTROL the shape in a comment passes
--   7 the corpus (scripts/lua, lib/lua) is clean      8 a directory that is not there is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-lua-posix-only-absolute.lua
-- Verdict: ok:lua-posix-only-absolute-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("lua-posix-only-absolute-fixture")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local function check(dirs)
    local argv = { PLAN, "script", "run", "scripts/lua/check-lua-posix-only-absolute.lua" }
    if dirs then argv[#argv + 1] = "--"; for _, d in ipairs(dirs) do argv[#argv + 1] = d end end
    argv.cwd, argv.env_unset, argv.timeout_ms = ROOT, { "TILLANDSIAS_*" }, 60000
    local r = T:run(argv)
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400)
end
local function planted(body)
    local d = T:scratch()
    fs.write(d.rel .. "/x.lua", "local P = arg[1]\n" .. body .. "\n")
    return check{ d.rel }
end
local function arm(name, refused, body)
    local rc, o, why = planted(body)
    T:arm(name, refused and rc == 1 and text.contains(o, "x.lua:2:") and text.contains(o, "violation:lua-posix-only-absolute:1")
        or not refused and rc == 0 and text.contains(o, "ok:lua-posix-only-absolute:1 files"), why)
end
arm('1 p:sub(1, 1) ~= "/" is refused by line', true, 'if P:sub(1, 1) ~= "/" then P = "root/" .. P end')
arm("2 the same with other spacing is refused", true, 'if P:sub( 1,1 )~="/" then P = "root/" .. P end')
arm("3 CONTROL the same line accepting a drive path passes", false, 'if P:sub(1, 1) ~= "/" and not P:find("^%a:[/\\\\]") then P = "root/" .. P end')
arm("4 CONTROL fixture.is_abs passes", false, 'if not fixture.is_abs(P) then P = "root/" .. P end')
arm('5 CONTROL an == "/" test passes', false, 'if P:sub(1, 1) == "/" then return end')
arm("6 CONTROL the shape in a comment passes", false, '-- never write P:sub(1, 1) ~= "/" here')
local rc, o, why = check(nil)
T:arm("7 the corpus is clean", rc == 0 and text.contains(o, "ok:lua-posix-only-absolute:"), why)
rc, o, why = check{ "target/plan-scratch/no-such-dir-2402" }
T:arm("8 a directory that is not there is refused", rc == 1 and text.contains(o, "refused:lua-posix-only-absolute:no-dir:"), why)
T:finish()
