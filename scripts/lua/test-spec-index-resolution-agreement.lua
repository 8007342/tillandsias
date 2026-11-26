-- @env PATH HOME
-- @trace spec:forge-environment-discoverability, order:801-a2by, order:2391-d389
--
-- test-spec-index-resolution-agreement.lua — scripts/lua/check-spec-index-resolution-agreement.lua on a scratch copy
-- of its three carriers: the real tree agrees; a block drifted in one carrier, a carrier that lost its markers, a
-- block whose resolver is gone, a chain reordered in every carrier's text but resolving differently, and a
-- producer that ignores its own block are each refused by name. The .sh's --selftest, as arms.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-index-resolution-agreement.lua
-- Verdict: ok:spec-index-resolution-agreement-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("spec-index-resolution-agreement-fixture")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local SUBJECT = "scripts/lua/check-spec-index-resolution-agreement.lua"
local CARRIERS = { "scripts/spec-index-ensure.sh", "images/default/config-overlay/mcp/forge-plan.sh", "images/default/lib-expert-capability.sh" }
local ORIG = {}
for _, c in ipairs(CARRIERS) do ORIG[c] = fs.read(c):gsub("\r\n", "\n") end

-- A fresh checkout-shaped scratch dir, carriers as given (nil = absent).
local function tree(over)
    local d = T:scratch()
    for _, sub in ipairs{ "scripts", "images", "images/default", "images/default/config-overlay", "images/default/config-overlay/mcp" } do fs.mkdir(d.rel .. "/" .. sub) end
    for _, c in ipairs(CARRIERS) do
        local body = ORIG[c]
        if over and over[c] ~= nil then body = over[c] end
        if body then fs.write(d.rel .. "/" .. c, body) end
    end
    -- The producer sources its siblings; the ones it needs come along.
    for _, f in ipairs{ "scripts/plan-binary-probe.sh", "scripts/common.sh" } do
        if fs.exists(f) then fs.write(d.rel .. "/" .. f, (fs.read(f):gsub("\r\n", "\n"))) end
    end
    return d
end
local function judge(d)
    local r = T:run{ PLAN, "script", "run", SUBJECT, "--", "--root", d.abs, env_unset = { "TILLANDSIAS_*", "FORGE_*" } }
    local line = text.trim((r.stdout or ""):gsub("\r", ""))
    return { code = r.code, line = line, got = "rc=" .. tostring(r.code) .. " " .. line .. " " .. (r.stderr or ""):sub(1, 200) }
end
local function swap(s, from, to)
    local a, b = s:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return s:sub(1, a - 1) .. to .. s:sub(b + 1)
end
local BEGIN = "# >>> BEGIN spec-index resolution (801-a2by)"
local P, F, L = CARRIERS[1], CARRIERS[2], CARRIERS[3]

local x = judge(tree())
T:arm("1 CONTROL the three carriers agree, textually and under every scenario", x.code == 0 and x.line == "ok:spec-index-resolution-agreement:carriers=3-scenarios=4", x.got)
x = judge(tree{ [F] = swap(ORIG[F], BEGIN, BEGIN .. "\n# a drift") })
T:arm("2 a block drifted in one carrier is refused, naming it", x.code == 1 and x.line == "violation:spec-index-resolution:block-drift:" .. F, x.got)
x = judge(tree{ [L] = swap(ORIG[L], BEGIN, "# >>> BEGIN something else") })
T:arm("3 a carrier without the markers is refused, never read as agreeing", x.code == 1 and x.line:find("^violation:spec%-index%-resolution:no%-resolution%-block:" .. L:gsub("%p", "%%%0")) ~= nil, x.got)
x = judge(tree{ [L] = false })
T:arm("3 a carrier that is gone is refused", x.code == 1 and x.line == "violation:spec-index-resolution:carrier-missing:" .. L, x.got)
local NORES = {}
for _, c in ipairs(CARRIERS) do NORES[c] = swap(ORIG[c], "_tillandsias_spec_index_paths()", "_renamed_paths()") end
x = judge(tree(NORES))
T:arm("4 a block with no resolver is refused", x.code == 1 and x.line == "violation:spec-index-resolution:block-has-no-resolver:" .. P, x.got)
-- The same bytes in all three, but the block no longer prints two paths: the behavioural half catches it.
local EMPTY = {}
for _, c in ipairs(CARRIERS) do EMPTY[c] = swap(ORIG[c], "_tillandsias_spec_index_paths() {", "_tillandsias_spec_index_paths() { return 0\n") end
x = judge(tree(EMPTY))
T:arm("5 identical blocks that resolve nothing are refused, not agreed", x.code == 1 and x.line:find("^violation:spec%-index%-resolution:resolver%-") ~= nil, x.got)
-- The producer carries the block but resolves --where some other way.
local WHERE = ORIG[P]:gsub("spec%-index:root=", "spec-index:root=/elsewhere#", 1)
x = judge(tree{ [P] = WHERE })
T:arm("6 a producer that ignores its own block is refused", x.code == 1 and x.line:find("^violation:spec%-index%-resolution:producer%-ignores%-its%-own%-block") ~= nil, x.got)

T:finish()
