-- @trace order:1616-njfd
-- @env PATH
--
-- test-preflight-regime-budget.lua — the front door's budget is chosen per
-- regime from measurement (1616-njfd), and the front door judges by it.
--
-- build.sh's _pf_budget and test-preflight-front-door.sh's judge_budget are
-- EXTRACTED at run time, not copied.
--   1 REGIMES   _pf_budget, with `uname` and `ps` shims standing in for the
--               host: Darwin at priority 4 (taskpolicy -b) is
--               415 darwin-background; Darwin at 31 is 200 darwin; Linux is
--               150 floor; TILLANDSIAS_PREFLIGHT_BUDGET_S=999 wins over all
--   2 PASS-NEW  a darwin -b summary at wall=380s that names its budget
--               (budget=415s budget-regime=darwin-background) is judged ok
--   3 FAIL-FLAT the same summary under the flat 150 s
--               (TILLANDSIAS_PREFLIGHT_BUDGET_S=150) is judged a FAIL: arms 2
--               and 3 are the row's "passes under the new budget and fails under
--               the flat 150, in one run"
--   4 OLD-DOOR  a summary from a door older than 1616 (no budget=) falls back
--               to the floor's 150 s, so 380 s fails as it always did
--   5 LAST-LINE a guard's own `wall=1s` printed before the summary is not
--               read as the run's wall
--   6 CLOCK     the deadline clock this bash gives (_pf_now): wall-us on
--               bash >= 5, wall-s otherwise, printed so a gate's log shows which
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-regime-budget.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("preflight-regime-budget", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/regime-budget-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/shim")

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

local function extract(text_, name)
    local acc, on = {}, false
    for l in (text_ .. "\n"):gmatch("(.-)\n") do
        if l:match("^" .. name .. "%(%) {") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "}" then break end
        end
    end
    return table.concat(acc, "\n")
end
local budget_fn = extract(fs.read("build.sh"), "_pf_budget")
local now_fn = extract(fs.read("build.sh"), "_pf_now")
local judge_fn = extract(fs.read("scripts/test-preflight-front-door.sh"), "judge_budget")
if budget_fn == "" or judge_fn == "" then
    verdict.emit("violation:preflight-regime-budget:no-subject", 1,
        "build.sh has no _pf_budget or test-preflight-front-door.sh no judge_budget (1616-njfd)")
end

-- ── 1 the regime table ─────────────────────────────────────────────────────
fs.write(REL .. "/shim/uname", "#!/bin/sh\necho \"$FAKE_UNAME\"\n")
fs.write(REL .. "/shim/ps", "#!/bin/sh\necho \"  $FAKE_PRI\"\n")
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/shim/uname", ROOT .. "/" .. REL .. "/shim/ps" }, timeout_ms = 10000 })
fs.write(REL .. "/budget.sh", budget_fn .. '\nPATH="$SHIM:$PATH"\n_pf_budget\necho "$_PF_BUDGET $_PF_BUDGET_REGIME"\n')
local function regime(uname, pri, override)
    local e = { SHIM = ROOT .. "/" .. REL .. "/shim", FAKE_UNAME = uname, FAKE_PRI = pri }
    if override then e.TILLANDSIAS_PREFLIGHT_BUDGET_S = override end
    return text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/budget.sh" }, env = e, timeout_ms = 10000 }).stdout or "")
end
local bg, dw, lx, ov = regime("Darwin", "4"), regime("Darwin", "31"), regime("Linux", "20"), regime("Darwin", "4", "999")
arm("1 REGIMES darwin -b 415, darwin 200, Linux 150, and the override wins",
    bg == "415 darwin-background" and dw == "200 darwin" and lx == "150 floor" and ov == "999 override",
    "darwin-pri4=[" .. bg .. "] darwin-pri31=[" .. dw .. "] linux=[" .. lx .. "] override=[" .. ov .. "]")

-- ── 2-5 the front door's judge ─────────────────────────────────────────────
fs.write(REL .. "/judge.sh", table.concat({
    "ok()  { printf 'OK %s\\n' \"$1\"; }",
    "bad() { printf 'BAD %s\\n' \"$1\"; }",
    judge_fn,
    'judge_budget "$(cat "$1")"',
    "" }, "\n"))
local SUMMARY_380 = "partial:preflight:ran=162 declared-skip=10 skipped-by-deadline=69 could-not-run=0 refused=0 sum=241 " ..
    "isolation=none-no-setsid deadline-clock=wall-s budget=415s budget-regime=darwin-background wall=380s\n"
local OLD_380 = "partial:preflight:ran=162 declared-skip=10 skipped-by-deadline=69 could-not-run=0 refused=0 sum=241 " ..
    "isolation=none-no-setsid wall=380s\n"
local function judge(name, body, flat)
    fs.write(REL .. "/" .. name .. ".out", body)
    local e = {}
    if flat then e.TILLANDSIAS_PREFLIGHT_BUDGET_S = flat end
    return text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/judge.sh", ROOT .. "/" .. REL .. "/" .. name .. ".out" },
        env = e, timeout_ms = 10000 }).stdout or "")
end
local o = judge("new", SUMMARY_380)
arm("2 PASS-NEW a darwin -b run at 380 s passes under its regime's 415 s budget",
    o:find("^OK ") ~= nil and o:find("380s <= 415s, regime darwin-background", 1, true) ~= nil, o)
o = judge("flat", SUMMARY_380, "150")
arm("3 FAIL-FLAT the same run under the flat 150 s fails",
    o:find("^BAD ") ~= nil and o:find("380s > 150s", 1, true) ~= nil, o)
o = judge("old", OLD_380)
arm("4 OLD-DOOR a summary with no budget= is judged against the floor's 150 s",
    o:find("^BAD ") ~= nil and o:find("380s > 150s, the floor default", 1, true) ~= nil, o)
o = judge("last", "note: a guard printed wall=1s in its own output\n" .. SUMMARY_380, "150")
arm("5 LAST-LINE a guard's own wall=1s before the summary is not the run's wall",
    o:find("380s > 150s", 1, true) ~= nil, o)

-- ── 6 the clock, observed ──────────────────────────────────────────────────
if now_fn == "" then
    arm("6 CLOCK premise: build.sh has _pf_now (1614-5x7m)", false, "no _pf_now")
else
    fs.write(REL .. "/clock.sh", now_fn .. "\n_pf_now; echo \"$_PF_CLOCK ${BASH_VERSINFO[0]}\"\n")
    local c = text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/clock.sh" }, timeout_ms = 10000 }).stdout or "")
    local clock, major = c:match("^(%S+) (%d+)$")
    local os_ = text.trim(proc.run({ argv = { "uname", "-s" }, timeout_ms = 10000 }).stdout or "")
    local want = (tonumber(major or "0") >= 5) and "wall-us" or "wall-s"
    arm("6 CLOCK this host's deadline clock is the one its bash can give",
        clock == want, "observed: deadline-clock=" .. tostring(clock) .. " on " .. os_ .. " bash " .. tostring(major))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:preflight-regime-budget:" .. #failed .. "-failed", 1)
end
verdict.ok("preflight-regime-budget", "6 arms")
