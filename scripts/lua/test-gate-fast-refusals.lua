-- @trace order:1009-gccx, order:1142-85zx, order:2342-9f4k
-- @env TILLANDSIAS_GATE_FAST_REFUSAL_E2E
--
-- test-gate-fast-refusals.lua — the gate refuses a sub-second-decidable defect BEFORE
-- it compiles anything. Measured on lenovinha 2026-09-04 with one planted exec-bit
-- defect: 222s to refusal before the reorder, 2s after. Ported from the .sh (2342-9f4k).
--
-- It pins the ORDER in build.sh, not any single check:
--   1 the fast-refusal phase is declared before the first compile step
--   2 no hoisted guard resolves the plan binary: on a cold tree it would SKIP. A
--     source-shape test: it misses a guard that degrades another way (yoga)
--   3 885-92iu is invoked once, AFTER the first compile (it needs the built binary)
--   4 each hoisted guard is invoked exactly once. INVOCATIONS, not mentions: a comment
--     naming a guard once counted as a call (1034-ihxw). The memoised-plan arm is
--     EXCISED first, because it exits before the hoisted phase, so a call there runs
--     instead of the hoisted one (1142-85zx); an excision that removed nothing is red.
--   5 (opt-in, TILLANDSIAS_GATE_FAST_REFUSAL_E2E=1) a forced gate on a planted defect
--     refuses with no compile entered. Forced: the memo is keyed on bytes and a chmod
--     changes none, so without TILLANDSIAS_FORCE_CHECK=1 it returns green (765-tkq2)
--
-- Verdict: ok:test-gate-fast-refusals:<n> | violation:gate-fast-refusals:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-fast-refusals")
local ROOT = fixture.repo_root()
local VICTIM = "scripts/check-litmus-pin-claims.sh"
if not fs.exists(VICTIM) then T:skip("victim-absent:" .. VICTIM) end
local HOISTED = { "check-scorable-obligation-added", "check-issue-citation-convention", "check-script-exec-bits", "check-litmus-pin-claims" }

local all = {}
for l in (fs.read("build.sh") .. "\n"):gmatch("([^\n]*)\n") do all[#all + 1] = l end
local function first(s) for i, l in ipairs(all) do if l:find(s, 1, true) then return i end end end
local fast = first("Fast refusals: sub-second deciders")
local clippy = first('_step "Running clippy (strict; includes the workspace type-check)')
T:arm("1 the fast-refusal phase is declared before the first compile step", fast and clippy and fast < clippy, "fast=" .. tostring(fast) .. " clippy=" .. tostring(clippy))

local hoisted, inarm = {}, false
for _, l in ipairs(all) do
    if l:find('"ok:gate-fresh-except-plan "*)', 1, true) then inarm = true end
    if inarm and l:find("^%s*;;%s*$") then inarm = false
    elseif not inarm then hoisted[#hoisted + 1] = l end
end
local why = {}
for _, g in ipairs(HOISTED) do
    local n = 0
    for _, l in ipairs(hoisted) do if l:find("_run bash .*" .. g:gsub("%-", "%%-") .. "%.sh") then n = n + 1 end end
    if n ~= 1 then why[#why + 1] = g .. ".sh is invoked " .. n .. " times outside the memoised-plan arm" end
end
if #hoisted >= #all then why[#why + 1] = "the memoised-plan arm was not excised" end

local cold = {}
for _, g in ipairs(HOISTED) do
    if fs.exists("scripts/" .. g .. ".sh") and fs.read("scripts/" .. g .. ".sh"):find("resolve_plan_binary", 1, true) then cold[#cold + 1] = g end
end
T:arm("2 no hoisted guard depends on a built binary", #cold == 0, table.concat(cold, ", ") .. " would SKIP on a cold tree (885-92iu)")

local dc, dn
for i, l in ipairs(all) do
    if l:find('_run_lua_decider "scripts/lua/check-declared-closures-added.lua"', 1, true) then dc = dc or i; dn = (dn or 0) + 1 end
end
T:arm("3 885-92iu is invoked once, after the first compile", dn == 1 and clippy and dc > clippy, "calls=" .. tostring(dn or 0) .. " line=" .. tostring(dc) .. " clippy=" .. tostring(clippy))
T:arm("4 each hoisted guard is invoked exactly once", #why == 0, table.concat(why, "; "))

if env.get("TILLANDSIAS_GATE_FAST_REFUSAL_E2E") ~= "1" then
    out.line("note: behavioural arm skipped (set TILLANDSIAS_GATE_FAST_REFUSAL_E2E=1; it runs a forced gate)")
else
    T:must{ "chmod", "-x", ROOT .. "/" .. VICTIM }
    local t0 = time.now_ms()
    local ran, r = pcall(T.run, T, { ROOT .. "/build.sh", "--check", cwd = ROOT, env = { TILLANDSIAS_FORCE_CHECK = "1" }, timeout_ms = 1800000 })
    T:must{ "chmod", "+x", ROOT .. "/" .. VICTIM }
    local said = ran and (r.stdout or "") .. (r.stderr or "") or tostring(r)
    local took = math.floor((time.now_ms() - t0) / 1000) .. "s"
    T:arm("5 a planted exec-bit defect is refused in " .. took .. " with no compile entered", ran and r.code ~= 0
        and said:find("violation:script-not-executable", 1, true) ~= nil and not said:find("Running clippy", 1, true),
        "rc=" .. tostring(ran and r.code) .. " " .. said:sub(-400))
end
T:finish({ ok = function(n) return "ok:test-gate-fast-refusals:" .. n end })
