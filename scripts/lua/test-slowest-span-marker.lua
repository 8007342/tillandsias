-- @trace order:785-ibu9, order:1588-27v3
--
-- test-slowest-span-marker.lua — order 785-ibu9, the slowest= provenance marker.
-- A build-span record is wall clock between banners, not the named step's own
-- cost, so the one number a cycle reads first must say which it is.
--
-- PORTED from scripts/test-slowest-span-marker.sh, arm for arm, as 1588-27v3's
-- carried shell-to-lua item. The timing logs are written under
-- target/plan-scratch and removed afterwards.
--
-- Arms:
--   1 SPAN     a build-span slowest is marked `~span`
--   2 BUILD    an attributable slowest carries no marker
--   3 LEGACY   a pre-785 record with no phase field is unaffected
--
-- Verdict: ok:slowest-span-marker-fixture:3, or
--          violation:slowest-span-marker-fixture:<passed>/3
--
-- Usage: tillandsias-plan script run scripts/lua/test-slowest-span-marker.lua
local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.emit("could-not-run:slowest-span-marker-fixture:no-checkout", 3) end

local T_REL = "target/plan-scratch/slowest-span-marker-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(T_REL)

-- The `timing:` line cycle-metrics.sh prints for a timing log holding `records`.
local function timing_line(name, records)
    local log = T_REL .. "/" .. name .. ".jsonl"
    fs.write(log, records)
    local r = run({ "bash", ROOT .. "/scripts/cycle-metrics.sh", "--experts-only", "--no-experts" },
        { env = { TILLANDSIAS_TIMING_LOG = ROOT .. "/" .. log } })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:sub(1, 7) == "timing:" then return l end
    end
    return ""
end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local passed = 0
local function check(name, line, want)
    if has(line, want) then passed = passed + 1; out.line("ok: " .. name)
    else out.line("FAIL: " .. name .. " — " .. line) end
end

check("a span-provenance slowest is marked ~span",
    timing_line("span", '{"step":"step:coarse","phase":"build-span","duration_ms":9000}\n{"step":"step:fast","phase":"build","duration_ms":5}\n'),
    "slowest=step:coarse~span:9000")
check("an attributable slowest carries no marker",
    timing_line("work", '{"step":"step:real","phase":"build","duration_ms":7000}\n'),
    "slowest=step:real:7000")
-- Pre-785 logs carry no phase field at all and must keep working unmarked.
check("pre-785 records without a phase field are unaffected",
    timing_line("legacy", '{"step":"step:legacy","duration_ms":4000}\n'),
    "slowest=step:legacy:4000")

run({ "rm", "-rf", ROOT .. "/" .. T_REL })
if passed ~= 3 then verdict.emit(("violation:slowest-span-marker-fixture:%d/3"):format(passed), 1) end
verdict.emit("ok:slowest-span-marker-fixture:3", 0)
