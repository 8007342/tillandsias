-- @env PATH HOME
-- @trace order:2080-kkki
--
-- test-cheatsheet-provenance.lua — check-cheatsheet-provenance.lua refuses a staged cheatsheet with
-- no ## Provenance section unless the floor lists it, and refuses a floor that did not shrink.
-- Every arm but the last judges a scratch tree (the real staged tree is never written).
--   1 CLEAN    sheets with provenance, an empty floor: ok
--   2 NEW      a sheet with no provenance that the floor does not list: refused by name (red on
--              trunk: nothing refused it, and check-cheatsheet-sources exited zero)
--   3 FLOORED  the same sheet listed on the floor: ok
--   4 STALE    a floor line whose sheet now has provenance: refused (the floor only shrinks)
--   5 GONE     a floor line naming no staged sheet: refused
--   6 EXEMPT   INDEX.md and TEMPLATE.md without provenance: ok
--   7 REAL     the real staged tree and the committed floor: ok
--
-- Usage: tillandsias-plan script run scripts/lua/test-cheatsheet-provenance.lua
-- Verdict: ok:cheatsheet-provenance-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cheatsheet-provenance-fixture")
local PLAN = fixture.plan_binary()
local CHECK = "scripts/lua/check-cheatsheet-provenance.lua"
local PROV = "# x\n\nbody\n\n## Provenance\n\n- https://example.invalid/doc\n"
local BARE = "# y\n\nbody, no sources\n"
local n = 0
local function case(files, floor)
    n = n + 1
    local d = T:scratch()
    fs.mkdir(d.rel .. "/sheets/runtime")
    for rel, body in pairs(files) do fs.write(d.rel .. "/sheets/" .. rel, body) end
    fs.write(d.rel .. "/floor.txt", "# floor\n" .. table.concat(floor, "\n") .. (#floor > 0 and "\n" or ""))
    local r = T:run{ PLAN, "script", "run", CHECK, "--", "--root", d.rel .. "/sheets", "--floor", d.rel .. "/floor.txt", timeout_ms = 60000, refusal_ok = true }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local c, o = case({ ["runtime/a.md"] = PROV }, {})
T:arm("1 CLEAN sheets with provenance and an empty floor pass", c == 0 and text.contains(o, "ok:cheatsheet-provenance:1 sheets 0 on the floor"), o)
c, o = case({ ["runtime/a.md"] = PROV, ["runtime/b.md"] = BARE }, {})
T:arm("2 NEW a sheet with no provenance the floor does not list is refused by name", c == 1 and text.contains(o, "no-provenance: runtime/b.md"), o)
c, o = case({ ["runtime/a.md"] = PROV, ["runtime/b.md"] = BARE }, { "runtime/b.md" })
T:arm("3 FLOORED the same sheet on the floor passes", c == 0, o)
c, o = case({ ["runtime/a.md"] = PROV }, { "runtime/a.md" })
T:arm("4 STALE a floor line whose sheet now has provenance is refused", c == 1 and text.contains(o, "floor-stale: runtime/a.md has a Provenance section now"), o)
c, o = case({ ["runtime/a.md"] = PROV }, { "runtime/gone.md" })
T:arm("5 GONE a floor line naming no staged sheet is refused", c == 1 and text.contains(o, "floor-stale: runtime/gone.md is no longer a staged sheet"), o)
c, o = case({ ["runtime/a.md"] = PROV, ["INDEX.md"] = BARE, ["TEMPLATE.md"] = BARE }, {})
T:arm("6 EXEMPT INDEX.md and TEMPLATE.md need no provenance", c == 0, o)
local r = T:run{ PLAN, "script", "run", CHECK, timeout_ms = 120000, refusal_ok = true }
T:arm("7 REAL the real staged tree and committed floor pass", r.code == 0 and text.contains(r.stdout or "", "ok:cheatsheet-provenance:"), (r.stdout or "") .. (r.stderr or ""))
T:finish()
