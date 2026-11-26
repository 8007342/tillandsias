-- @trace order:1064-5hv2, order:1586-gway, order:2342-9f4k
--
-- test-hook-phase-instrumentation.lua — the pre-commit hook reports its own per-phase
-- timings on request, and the drift warning names the MULTIPLE. Two hosts had made
-- throwaway copies with the warning forced true to read it. Ported from the .sh
-- (2342-9f4k).
--
--   1 silent unless asked
--   2 asked, every phase is reported (4 or more) with elapsed, budget and multiple
--   3 an over-budget phase warns and the warning names the multiple
--   4 the 1x-to-4x BLIND BAND IS STILL OPEN, asserted on purpose: closing it changes
--     warning volume on every commit, so the day someone does, this arm makes them
--     read 1064-5hv2. The budget is CALIBRATED to half the phase's measured time
--     (1586-gway: a fixed 30 ms was red on every darwin gate), and only a run the
--     hook's own table places in the band counts; three tries, never a default pass
-- 3 and 4 run a COPY of the hook with an injected slow phase: no real phase is slow
-- enough on a healthy tree.
--
-- Verdict: ok:hook-phase-instrumentation:<n> arms | violation:hook-phase-instrumentation:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("hook-phase-instrumentation")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local HOOK = ROOT .. "/scripts/hooks/pre-commit-openspec.sh"
local W = T:scratch()

local function hook(path, timing)
    local r = T:run{ SH, path, cwd = ROOT, env = timing and { TILLANDSIAS_HOOK_PHASE_TIMING = "1" } or nil,
        env_unset = { "TILLANDSIAS_HOOK_PHASE_TIMING" }, timeout_ms = 120000 }
    return (r.stdout or "") .. (r.stderr or "")
end

local o = hook(HOOK, false)
T:arm("1 silent unless requested", not o:find("OpenSpec phase:", 1, true), o:sub(1, 300))

o = hook(HOOK, true)
local n, numbers = 0, false
for l in (o .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("OpenSpec phase:", 1, true) then
        n = n + 1
        if l:find("OpenSpec phase:.*%d+ms.*budget.*%d+%.%d+x") then numbers = true end
    end
end
T:arm("2 every phase is reported when asked", n >= 4, n .. " phases")
T:arm("2 the lines carry elapsed, budget and the multiple", numbers, o:sub(1, 300))

-- Two injections, each at its FIRST occurrence: a 1 ms budget and one call.
local src = fs.read("scripts/hooks/pre-commit-openspec.sh")
local BUDGET = "        zero_trace_check)       echo 2500 ;;\n"
local function inject(ms)
    local i, j = src:find(BUDGET, 1, true)
    local k = src:find("run_phase ghost_check", 1, true)
    if not (i and k) then return nil end
    k = src:sub(1, k):match(".*\n()") or 1
    return src:sub(1, j) .. "        _fixture_slow_phase)    echo " .. ms .. " ;;\n" .. src:sub(j + 1, k - 1)
        .. "_fixture_slow_phase() { sleep 0.05; }\nrun_phase _fixture_slow_phase\n" .. src:sub(k)
end
local slow = inject(1)
if not slow then T:refuse("no-subject", "the hook's budget line or ghost_check call moved") end
fs.write(W.rel .. "/hook.sh", slow)
o = hook(W.abs .. "/hook.sh", false)
local warn = o:match("[^\n]*_fixture_slow_phase took[^\n]*") or ""
T:arm("3 an over-budget phase still warns", warn ~= "", o:sub(-300))
T:arm("3 the warning names the multiple", warn:find("x its", 1, true) ~= nil, warn)

local cal = tonumber(warn:match("_fixture_slow_phase took (%d+)ms"))
local banded, el, budget
for _ = 1, 3 do
    if not cal then break end
    budget = math.max(1, (cal + 1) // 2)
    fs.write(W.rel .. "/hook.sh", inject(budget))
    o = hook(W.abs .. "/hook.sh", true)
    el = tonumber(o:match("OpenSpec phase: _fixture_slow_phase *(%d+)ms"))
    if el and el > budget and el <= budget * 4 then banded = el .. "/" .. budget; break end
    cal = el
end
T:arm("4 the injected phase is inside the 1x-to-4x band", banded ~= nil, "last " .. tostring(el) .. "ms against " .. tostring(budget) .. "ms; arm 4 measured nothing")
T:arm("4 the blind band is still open (1064-5hv2)", banded ~= nil and not o:find("_fixture_slow_phase took", 1, true),
    "a phase at " .. tostring(banded) .. " ms warns: if intended, change this arm and 1064-5hv2 together, with the two-host volumes")
T:finish()
