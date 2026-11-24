-- @trace order:1616-njfd, order:1636-6k6k
-- @env PATH
--
-- test-preflight-regime-budget.lua — the front door's budget is chosen per
-- regime from measurement (1616-njfd), and the front door judges by it.
--
-- build.sh's _pf_budget and test-preflight-front-door.sh's judge_budget are
-- EXTRACTED at run time, not copied.
--   1 REGIMES   _pf_budget, with `uname` and `ps` shims standing in for the
--               host: Darwin at priority 4 (taskpolicy -b) is
--               450 darwin-background with a 20 s check-* decider deadline
--               (1636-6k6k, measured: the row at 7a990a936); Darwin at 31 is
--               200 darwin and Linux 150 floor, both still 5 s;
--               TILLANDSIAS_PREFLIGHT_BUDGET_S=999 wins over all, at 5 s
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
--   7 DECIDER   (1636-6k6k) the extracted launcher gives a check-* decider the
--               decider deadline and a fixture the door's: both take 3 s at
--               1 s / 10 s; the trunk launcher (no 4th argument) cuts both
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

-- On msys ROOT is C:/..., which a colon-separated PATH splits at the drive
-- (yolanda 2026-11-24): the shims were never found. /c/... works; elsewhere
-- ROOT is unchanged.
local PATH_ROOT = ROOT:match("^%a:/") and ("/" .. ROOT:sub(1, 1):lower() .. ROOT:sub(3)) or ROOT

-- ── 1 the regime table ─────────────────────────────────────────────────────
fs.write(REL .. "/shim/uname", "#!/bin/sh\necho \"$FAKE_UNAME\"\n")
fs.write(REL .. "/shim/ps", "#!/bin/sh\necho \"  $FAKE_PRI\"\n")
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/shim/uname", ROOT .. "/" .. REL .. "/shim/ps" }, timeout_ms = 10000 })
fs.write(REL .. "/budget.sh", budget_fn .. '\nPATH="$SHIM:$PATH"\n_pf_budget\necho "$_PF_BUDGET $_PF_BUDGET_REGIME $_PF_DECIDER_DEADLINE"\n')
local function regime(uname, pri, override)
    local e = { SHIM = PATH_ROOT .. "/" .. REL .. "/shim", FAKE_UNAME = uname, FAKE_PRI = pri }
    if override then e.TILLANDSIAS_PREFLIGHT_BUDGET_S = override end
    return text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/budget.sh" }, env = e, timeout_ms = 10000 }).stdout or "")
end
local bg, dw, lx, ov = regime("Darwin", "4"), regime("Darwin", "31"), regime("Linux", "20"), regime("Darwin", "4", "999")
arm("1 REGIMES darwin -b 450 with a 20 s decider deadline; darwin 200, Linux 150 and the override at 5 s",
    bg == "450 darwin-background 20" and dw == "200 darwin 5" and lx == "150 floor 5" and ov == "999 override 5",
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

-- ── 5b the settled budget (2272-cuxh, coordinator ruling (2) 2026-11-23) ───
local fd = fs.read("scripts/test-preflight-front-door.sh")
local settled = { "ok()  { printf 'OK %s\\n' \"$1\"; }", "bad() { printf 'BAD %s\\n' \"$1\"; }", judge_fn }
for _, n in ipairs({ "_summary", "_contended", "_over_budget", "judge_settled_budget" }) do
    local fn = extract(fd, n)
    if fn == "" then
        -- a one-line function
        for _, l in ipairs(text.lines(fd)) do if l:sub(1, #n + 2) == n .. "()" then fn = l end end
    end
    if fn == "" then verdict.emit("violation:preflight-regime-budget:no-subject:" .. n, 1, "test-preflight-front-door.sh has no " .. n) end
    settled[#settled + 1] = fn
end
settled[#settled + 1] = '_budget_door() { i=$(( $(cat "$D/n") + 1 )); echo $i > "$D/n"; cat "$D/$i"; }'
settled[#settled + 1] = 'judge_settled_budget; echo "doors=$(cat "$D/n")"'
fs.write(REL .. "/settled.sh", table.concat(settled, "\n") .. "\n")
local function door(wall, benched, cont)
    return "partial:preflight:ran=280 declared-skip=10 skipped-by-deadline=3 benched=" .. benched ..
        " could-not-run=2 refused=0 sum=339 isolation=session budget=150s budget-regime=floor contention=" .. cont .. " wall=" .. wall .. "s\n"
end
local QUIET, LOUD = "cpu-some:0%,foreign:5%", "cpu-some:2%,foreign:54%"
local function settle(name, d1, d2, d3)
    local d = REL .. "/settled-" .. name
    fs.mkdir(d); fs.write(d .. "/n", "0")
    fs.write(d .. "/1", d1); fs.write(d .. "/2", d2 or ""); fs.write(d .. "/3", d3 or "")
    return text.trim(proc.run({ argv = { require("common.fixture").posix_shell(), ROOT .. "/" .. REL .. "/settled.sh" }, env = { D = ROOT .. "/" .. d }, timeout_ms = 10000 }).stdout or "")
end
local function has(s, w) return s:find(w, 1, true) ~= nil end
local s1 = settle("inside", door(140, 0, QUIET))
local s2 = settle("benched", door(158, 0, QUIET), door(158, 0, QUIET), door(80, 44, QUIET))
local s3 = settle("slow", door(158, 0, QUIET), door(158, 0, QUIET), door(170, 44, QUIET))
local s4 = settle("slow-unbenched", door(158, 0, QUIET), door(158, 0, QUIET), door(158, 0, QUIET))
local s5 = settle("loud", door(184, 0, LOUD), door(182, 0, LOUD), door(182, 0, LOUD))
local s6 = settle("loud-inside", door(140, 0, LOUD))
local s7 = settle("loud-benched", door(158, 0, QUIET), door(158, 0, QUIET), door(170, 44, LOUD))
arm("5b SETTLED door 1 inside passes alone; else door 3 decides, with benched= and the unbenched wall",
    has(s1, "OK ") and has(s1, "doors=1") and has(s1, "door=1 benched=0 contention=cpu-some:0%,foreign:5%")
        and has(s2, "OK ") and has(s2, "80s <= 150s") and has(s2, "door=3 benched=44 unbenched-wall=158s contention=cpu-some:0%,foreign:5%") and has(s2, "doors=3")
        and has(s3, "BAD ") and has(s3, "170s > 150s") and has(s4, "BAD "),
    s1 .. " | " .. s2 .. " | " .. s3 .. " | " .. s4)
arm("5c CONTENDED only an over-budget door with nothing benched on a contended host is named not-judged, never ok",
    has(s5, "not-judged:preflight-front-door:budget") and not has(s5, "OK ") and not has(s5, "BAD ")
        and has(s6, "OK ") and has(s7, "BAD "),
    s5 .. " | " .. s6 .. " | " .. s7)

-- ── 5d where only the start load can be read, a door waits out the one before it
local settle_fn = extract(fd, "_settle_start_load")
if settle_fn == "" then verdict.emit("violation:preflight-regime-budget:no-subject:_settle_start_load", 1, "test-preflight-front-door.sh has no _settle_start_load") end
fs.mkdir(REL .. "/mac")
fs.write(REL .. "/mac/sysctl", '#!/bin/sh\ncase "$2" in hw.ncpu) echo 10; exit 0 ;; esac\nn=$(( $(cat "$D/n") + 1 )); echo $n > "$D/n"\n' ..
    '[ "$LC_ALL" = C ] || { echo "{ 0,10 0,10 0,10 }"; exit 0; }\n[ "$n" -gt "$CALM" ] && echo "{ 1.20 2.00 2.00 }" || echo "{ 3.30 2.00 2.00 }"\n')
fs.write(REL .. "/mac/sleep", "#!/bin/sh\nexit 0\n")
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/mac/sysctl", ROOT .. "/" .. REL .. "/mac/sleep" }, timeout_ms = 10000 })
fs.write(REL .. "/settle.sh", settle_fn .. '\nPATH="$SHIM:$PATH"\n_settle_start_load 60; echo "reads=$(cat "$D/n")"\n')
local function settle_reads(calm, procfile)
    fs.write(REL .. "/mac/n", "0")
    return text.trim(proc.run({ argv = { require("common.fixture").posix_shell(), ROOT .. "/" .. REL .. "/settle.sh" },
        env = { D = ROOT .. "/" .. REL .. "/mac", CALM = calm, _SETTLE_PROC = procfile, LC_ALL = "fr_CH.UTF-8",
            -- set in the shell: Git's bash.exe prepends its own dirs to an inherited PATH
            SHIM = PATH_ROOT .. "/" .. REL .. "/mac" }, timeout_ms = 20000 }).stdout or "")
end
local w1, w2, w3 = settle_reads("2", "/nonexistent"), settle_reads("99", "/nonexistent"), settle_reads("99", ROOT .. "/build.sh")
arm("5d SETTLE it waits until the load drains, gives up at its bound, and never waits where /proc answers",
    w1 == "reads=3" and w2 == "reads=6" and w3 == "reads=0", w1 .. " | " .. w2 .. " | " .. w3)

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

-- ── 7 the decider deadline reaches the launcher (1636-6k6k) ────────────────
-- build.sh's launcher and its helpers, extracted, over a scratch root with a
-- check-* decider and a test-* fixture that each take 3 s: at a 1 s door
-- deadline and a 10 s decider deadline the decider answers and the fixture is
-- cut (124). Without the decider deadline (the trunk launcher's three
-- arguments) both are cut, which is what darwin-background's door did to the
-- 13 deciders in the row.
local parts = { "_preflight_preconditions() { :; }" }
for _, n in ipairs({ "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch",
    "_pf_sweep_declared_artifacts", "_pf_index_lock_held", "_pf_sweep_index_lock", "_pf_now", "_pf_run_guard", "_pf_predecide", "_pf_guard_deadline", "_pf_launcher" }) do
    local fn = extract(fs.read("build.sh"), n)
    if fn == "" and n ~= "_pf_sweep_declared_artifacts" and n ~= "_pf_index_lock_held" and n ~= "_pf_sweep_index_lock" then
        verdict.emit("violation:preflight-regime-budget:no-subject:" .. n, 1, "build.sh has no " .. n .. " (1636-6k6k)")
    end
    parts[#parts + 1] = fn
end
fs.write(REL .. "/door.sh", table.concat(parts, "\n") .. "\n")
local D = REL .. "/door"
fs.mkdir(D .. "/scripts")
fs.write(D .. "/scripts/check-slow.sh", "#!/usr/bin/env bash\nsleep 3\necho ok:slow-decider\n")
fs.write(D .. "/scripts/test-slow.sh", "#!/usr/bin/env bash\nsleep 3\necho ok:slow-fixture\n")
local function launch(extra)
    fs.write(REL .. "/launch.sh", table.concat({
        'SCRIPT_DIR="$1"; . "$2"', 'W="$(mktemp -d)"',
        "printf 'scripts/check-slow.sh\\nscripts/test-slow.sh\\n' | _pf_launcher \"$W\" 1 2 " .. extra,
        'echo "decider=$(cut -d" " -f1 "$W/1.rc") fixture=$(cut -d" " -f1 "$W/2.rc")"', 'rm -rf "$W"', "" }, "\n"))
    return text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/launch.sh", ROOT .. "/" .. D, ROOT .. "/" .. REL .. "/door.sh" },
        timeout_ms = 60000 }).stdout or "")
end
local post7, pre7 = launch("10"), launch("")
arm("7 DECIDER a check-* decider gets the decider deadline and answers; a fixture keeps the door's and is cut",
    post7 == "decider=0 fixture=124" and pre7 == "decider=124 fixture=124",
    "with decider deadline [" .. post7 .. "] trunk launcher [" .. pre7 .. "]")

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:preflight-regime-budget:" .. #failed .. "-failed", 1)
end
verdict.ok("preflight-regime-budget", "10 arms")
