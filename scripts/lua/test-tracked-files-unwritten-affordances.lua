-- @env PATH
-- @trace order:1247-amcu, order:1063-363b, spec:methodology-accountability, order:2384-5fj5
--
-- test-tracked-files-unwritten-affordances.lua — every refusal of
-- scripts/lua/check-tracked-files-unwritten.lua says WHY it refused and WHAT would make it not a refusal
-- (1247-amcu): labelled "  why:" / "  remedy:" lines on stderr beside its unchanged stdout verdict.
--
-- Four refusals are reached before any file is hashed, so they are RUN; the rest are pinned STATICALLY.
--
--   1 no arguments refuses usage with why and remedy;
--   2 an unknown mode refuses with why and remedy;
--   3 verify with no baseline refuses with why and remedy;
--   4 snapshot of a checkout that is no git work tree refuses with why and remedy;
--   5 STATIC: every blocked: verdict goes through blocked(), which affords, and the violation follows the
--     stderr block that carries its why and remedy.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tracked-files-unwritten-affordances.lua
-- Verdict: ok:tracked-files-unwritten-affordances:<n> arms | violation:tracked-files-unwritten-affordances:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("tracked-files-unwritten-affordances")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local SUBJECT = "scripts/lua/check-tracked-files-unwritten.lua"
local function afforded(err) return err:find("  why: %S") ~= nil and err:find("  remedy: %S") ~= nil end
local function refuses(name, args, env_, want)
    local argv = { PLAN, "script", "run", SUBJECT, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.env = env_
    local r = T:run(argv)
    local so, se = text.trim(r.stdout or ""), r.stderr or ""
    T:arm(name, r.code == 2 and so == want and afforded(se), "rc=" .. tostring(r.code) .. " stdout=" .. so .. " stderr=" .. se)
end
refuses("1 no arguments refuses usage with why and remedy", {}, nil, "blocked:tracked-files-unwritten:usage")
refuses("2 an unknown mode refuses with why and remedy", { "frobnicate", "x" }, nil, "blocked:tracked-files-unwritten:unknown-mode:frobnicate")
refuses("3 verify with no baseline refuses with why and remedy", { "verify", "target/plan-scratch/tfu-no-such-baseline" }, nil,
    "blocked:tracked-files-unwritten:no-snapshot-at:target/plan-scratch/tfu-no-such-baseline")
refuses("4 snapshot outside a git work tree refuses with why and remedy", { "snapshot", "target/plan-scratch/tfu-unused", "/nonexistent-tfu-fixture" }, nil, "blocked:tracked-files-unwritten:not-a-git-repo")

-- 5 static: no verdict site without its affordance.
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local code = line:gsub("%-%-.*$", "")
    if code:find('verdict.emit("blocked:', 1, true) and not code:find("afford(", 1, true) then bare[#bare + 1] = n end
    if code:find('verdict.emit("violation:', 1, true) and not prev:find("log.raw(", 1, true) then bare[#bare + 1] = n end
    if code:find('"refused:', 1, true) then bare[#bare + 1] = n end
    prev = line
end
local _, uses = src:gsub("\n%s*blocked%(", "")
T:arm("5 every verdict site carries its why and remedy", #bare == 0 and uses >= 4, "bare lines: " .. table.concat(bare, ",") .. " blocked() uses=" .. uses)

T:finish()
