-- @trace order:2118-asur
-- @env TILLANDSIAS_PLAN_BIN PATH HOME
--
-- test-fixture-helpers-merge-clean.lua — litmus:fixture-helpers-merge-clean.
-- Operator 2026-11-20 (landing-pipeline P4 row 3): two sibling branches that
-- each added a helper to lib/lua/common/fixture.lua appended to the same spot
-- (just above `return M`) and conflicted. Helpers now live one per file in
-- lib/lua/common/fixture/, installed by the kit in name order.
--   NEGATIVE CONTROL: the old way (each branch appends a helper to
--   fixture.lua itself) conflicts.
--   With the split: each branch adds a file; the merge is clean and a test
--   run in the merged tree sees BOTH helpers and every moved one.
--   A helper that would replace a core method is refused by name.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<plan binary> tillandsias-plan script run scripts/lua/test-fixture-helpers-merge-clean.lua
-- Verdict: ok:fixture-helpers-merge-clean:<n> arms | violation:fixture-helpers-merge-clean:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fixture-helpers-merge-clean")

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not BIN or BIN == "" then T:refuse("no-plan-binary", "set TILLANDSIAS_PLAN_BIN (the litmus step does)") end

local KIT = { "lib/lua/common/fixture.lua", "lib/lua/common/verdict.lua" }
for _, f in ipairs(fs.walk("lib/lua/common/fixture", { suffix = ".lua" })) do KIT[#KIT + 1] = f end

local function helper(name)
    return "return function(T, ctx)\nfunction T:" .. name .. "() return \"" .. name .. "\" end\nend\n"
end
local PROBE = [[
local fixture = require "common.fixture"
local T = fixture.new("probe")
local names = {}
for _, m in ipairs{ "alpha", "beta", "git_repo", "short_scratch", "scratch", "arm", "finish" } do
    if type(T[m]) == "function" then names[#names + 1] = m end
end
out.line("have:" .. table.concat(names, ","))
verdict.emit("ok:probe:" .. #names, 0)
]]

local function repo(tag)
    local d = T:git_repo(tag)
    fs.mkdir(d.rel .. "/lib/lua/common/fixture")
    for _, f in ipairs(KIT) do fs.write(d.rel .. "/" .. f, fs.read(f)) end
    fs.write(d.rel .. "/probe.lua", PROBE)
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-q", "-m", "kit" }
    return d
end
local function g(d, ...) return T:must{ "git", "-C", d.abs, ... } end
local function merge(d)
    return T:run{ "git", "-C", d.abs, "merge", "-q", "--no-edit", "right" }
end

-- NEGATIVE CONTROL: the old way, both branches append above `return M`.
local c = repo("control")
local kit = fs.read(c.rel .. "/lib/lua/common/fixture.lua")
local function append(body, name)
    local i = body:find("\nreturn M\n", 1, true)
    return body:sub(1, i) .. "function T:" .. name .. "() return 1 end\n" .. body:sub(i + 1)
end
g(c, "checkout", "-q", "-b", "left")
fs.write(c.rel .. "/lib/lua/common/fixture.lua", append(kit, "alpha"))
g(c, "commit", "-q", "-a", "-m", "alpha in the kit")
g(c, "checkout", "-q", "main"); g(c, "checkout", "-q", "-b", "right")
fs.write(c.rel .. "/lib/lua/common/fixture.lua", append(kit, "beta"))
g(c, "commit", "-q", "-a", "-m", "beta in the kit")
g(c, "checkout", "-q", "left")
T:arm("control: two helpers appended to fixture.lua conflict", merge(c).code ~= 0,
    "merged clean — the fixture has no subject")

-- The split: each branch adds its own file.
local d = repo("split")
g(d, "checkout", "-q", "-b", "left")
fs.write(d.rel .. "/lib/lua/common/fixture/alpha.lua", helper("alpha"))
g(d, "add", "-A"); g(d, "commit", "-q", "-m", "alpha helper")
g(d, "checkout", "-q", "main"); g(d, "checkout", "-q", "-b", "right")
fs.write(d.rel .. "/lib/lua/common/fixture/beta.lua", helper("beta"))
g(d, "add", "-A"); g(d, "commit", "-q", "-m", "beta helper")
g(d, "checkout", "-q", "left")
local r = merge(d)
T:arm("with one file per helper the sibling merge is clean", r.code == 0, tostring(r.stderr))

local p = T:run{ BIN, "script", "run", "probe.lua", cwd = d.abs }
local have = (p.stdout or ""):match("have:([^\n]*)") or ""
T:arm("the merged kit installs both new helpers",
    have:find("alpha", 1, true) and have:find("beta", 1, true), have .. tostring(p.stderr))
T:arm("the moved helpers (git_repo, short_scratch) and the core still load",
    have:find("git_repo", 1, true) and have:find("short_scratch", 1, true)
        and have:find("scratch,arm,finish", 1, true), have)

-- A helper that replaces a core method is refused, never silently swapped.
fs.write(d.rel .. "/lib/lua/common/fixture/zz_bad.lua",
    "return function(T, ctx)\nfunction T:arm() return true end\nend\n")
local bad = T:run{ BIN, "script", "run", "probe.lua", cwd = d.abs }
T:arm("a helper replacing a core method is refused by name",
    bad.code ~= 0 and ((bad.stdout or "") .. (bad.stderr or "")):find("replaces the core method arm", 1, true) ~= nil,
    tostring(bad.stdout) .. tostring(bad.stderr))

T:finish()
