-- @trace order:1616-njfd, order:2272-cuxh, order:2404-grd6
--
-- preflight_judge.lua — how the front door's wall-clock budget is judged.
--
-- One home for the judge that test-preflight-front-door.lua runs and
-- test-preflight-regime-budget.lua (step 465) pins. Until 2404-grd6 these were
-- bash functions in test-preflight-front-door.sh, which step 465 extracted and
-- executed; the port moved them here so the .sh could go.
--
-- Pure over strings, except settle_start_load, whose process runner and sleep
-- are passed in so a fixture can stand in for the host.

local M = {}

M.FLOOR = 150

-- The LAST summary line, never a guard's own output, which may say wall= too.
function M.summary(out)
    local l = ""
    for _, x in ipairs(text.lines(out or "")) do
        if x:find(":preflight:ran=", 1, true) then l = x end
    end
    return l
end

-- The budget a summary is judged against, and where it came from.
-- override = TILLANDSIAS_PREFLIGHT_BUDGET_S as read by the caller ("" or nil = unset).
function M.budget_of(s, override)
    if override and override ~= "" then return tonumber(override), "TILLANDSIAS_PREFLIGHT_BUDGET_S" end
    local b, r = (s or ""):match("budget=(%d+)s budget%-regime=([%a-]+)")
    if b then return tonumber(b), "regime " .. r end
    return M.FLOOR, "the floor default"
end

function M.wall_of(s) return tonumber((s or ""):match("wall=(%d+)s") or "") end

function M.over_budget(s, override)
    local w = M.wall_of(s)
    return w ~= nil and w > M.budget_of(s, override)
end

-- A summary with no contention field cannot show the host was quiet: contended.
function M.contended(s)
    s = s or ""
    if s:find("contention=cpu-some:", 1, true) then
        local cs, fo = s:match("contention=cpu%-some:(%d+)%%,foreign:(%d+)%%")
        return cs ~= nil and (tonumber(cs) > 3 or tonumber(fo) > 15)
    end
    if s:find("contention=start-load:", 1, true) then
        local sl = s:match("contention=start%-load:(%d+)%%")
        return sl ~= nil and tonumber(sl) > 20
    end
    return true
end

-- Judge one door's output. Returns ok (bool), message.
function M.judge(out, override, note)
    local s = M.summary(out)
    local w = M.wall_of(s)
    local b, from = M.budget_of(s, override)
    if not w then return false, "the verdict does not report its wall clock" end
    if w <= b then
        return true, "the whole run completes inside the budget (" .. w .. "s <= " .. b .. "s, " .. from .. ")" .. (note or "")
    end
    return false, "the run exceeded the budget (" .. w .. "s > " .. b .. "s, " .. from .. ") — a guard grew slow, or the budget is wrong"
end

-- Door 1 inside its budget passes alone; otherwise two more doors run and door 3 is
-- judged. An over-budget door 3 that benched nothing on a contended host measured the
-- load: "not-judged", never a pass. door() runs one door and returns its output.
-- Returns kind ("ok" | "bad" | "not-judged"), message.
function M.settled(door, override)
    local o = door()
    local s = M.summary(o)
    local first
    if M.over_budget(s, override) then
        first = s:match("wall=(%d+)s")
        door()
        o = door(); s = M.summary(o)
        local n = tonumber(s:match("benched=(%d+)") or "0") or 0
        if M.over_budget(s, override) and n == 0 and M.contended(s) then
            return "not-judged", "not-judged:preflight-front-door:budget — every door was contended, so nothing could be benched and the wall measures the load: " .. s
        end
    end
    -- Always said, so a reader knows which door was judged and on what host.
    local n = s:match("benched=(%d+)") or "?"
    local c = s:match("contention=(%S+)") or "unstated"
    local note = first and (" door=3 benched=" .. n .. " unbenched-wall=" .. first .. "s contention=" .. c)
        or (" door=1 benched=" .. n .. " contention=" .. c)
    local ok, msg = M.judge(o, override, note)
    return ok and "ok" or "bad", msg
end

-- Where only the START load is readable (no /proc), the door before is still in it:
-- wait it out, at most limit seconds (macbookair 2026-11-24). opts:
--   run(argv) -> { code=, stdout= }   (required)
--   sleep(seconds)                     (required)
--   proc_stat = "/proc/stat"           the file whose readability means "skip"
-- Returns the number of seconds waited.
function M.settle_start_load(limit, opts)
    local run, sleep = opts.run, opts.sleep
    if run{ "test", "-r", opts.proc_stat or "/proc/stat" }.code == 0 then return 0 end
    local waited = 0
    while waited < limit do
        local lr = run{ "sysctl", "-n", "vm.loadavg", env = { LC_ALL = "C" } }
        local nr = run{ "sysctl", "-n", "hw.ncpu" }
        if lr.code ~= 0 or nr.code ~= 0 then return waited end
        local a2 = tonumber((text.trim(lr.stdout or ""):match("^%S*%s+(%S+)") or ""))
        local n = tonumber(text.trim(nr.stdout or ""))
        if not a2 or not n or n <= 0 or math.floor(100 * a2 / n) <= 15 then return waited end
        sleep(10); waited = waited + 10
    end
    return waited
end

return M
