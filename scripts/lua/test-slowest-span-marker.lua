-- @trace order:785-ibu9, order:1588-bzre
--
-- test-slowest-span-marker.lua — PORTED from test-slowest-span-marker.sh
-- (1588-bzre). Order 785-ibu9, the slowest= provenance marker: a build-span
-- record is wall clock between banners, not the named step's own cost, so the
-- one number a cycle reads first must say which it is.
--
--   1 a span-provenance slowest is marked ~span
--   2 an attributable (phase=build) slowest carries no marker
--   3 pre-785 records without a phase field are unaffected
--   4 READERS: the .sh's retired failure line (fail: slowest-span-marker ...)
--     has no reader in scripts/, the gate steps or the litmus specs; the count
--     of files searched is printed
--
-- Terminal line: ok:slowest-span-marker-fixture:<n> (unchanged; the litmus
-- step expects it) or refused:slowest-span-marker-fixture:<n> (1588-bzre: the
-- .sh printed `fail: ...`, which nothing read).

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/span-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end

-- The timing: line cycle-metrics.sh prints for a given timing log.
local function timing(name, jsonl)
    fs.write(REL .. "/" .. name, jsonl)
    local r = proc.run({ argv = { "bash", "scripts/cycle-metrics.sh", "--experts-only", "--no-experts" },
        env = { TILLANDSIAS_TIMING_LOG = ROOT .. "/" .. REL .. "/" .. name }, timeout_ms = 120000 })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:sub(1, 7) == "timing:" then return l end
    end
    return ""
end

local o = timing("span.jsonl", '{"step":"step:coarse","phase":"build-span","duration_ms":9000}\n{"step":"step:fast","phase":"build","duration_ms":5}\n')
if text.contains(o, "slowest=step:coarse~span:9000") then ok("a span-provenance slowest is marked ~span")
else bad("span slowest not marked — " .. o) end

o = timing("work.jsonl", '{"step":"step:real","phase":"build","duration_ms":7000}\n')
if text.contains(o, "slowest=step:real:7000") then ok("an attributable slowest carries no marker")
else bad("measured slowest wrongly marked — " .. o) end

o = timing("legacy.jsonl", '{"step":"step:legacy","duration_ms":4000}\n')
if text.contains(o, "slowest=step:legacy:4000") then ok("pre-785 records without a phase field are unaffected")
else bad("legacy record changed shape — " .. o) end

-- 4: the retired failure line, assembled so this file cannot match itself.
local NEEDLE = "fa" .. "il: slowest-span-marker"
local SELF = "scripts/lua/test-slowest-span-marker.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and text.contains(body, NEEDLE) then hits[#hits + 1] = f end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired fail: terminal line has 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired fail: line: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL } })
if failed == 0 then verdict.emit("ok:slowest-span-marker-fixture:" .. passed, 0) end
verdict.emit("refused:slowest-span-marker-fixture:" .. failed, 1)
