-- @trace order:1925-77h4
--
-- test-ci-full-refreshes-stale-plan-binary.lua — ./build.sh --ci-full asks
-- every plan binary it can name `validator-surface-hash --check` before the
-- pre-build litmus, rebuilds once on a stale answer, and refuses when a copy
-- is still stale. The block between BEGIN-PLAN-BIN-CURRENT / END-PLAN-BIN-CURRENT
-- runs extracted, over a planted stub binary and a fake cargo, so nothing is
-- built:
--   1 REBUILT     stale stub, cargo rebuilds it: green, one cargo call
--   2 STILL-STALE stale stub, cargo leaves it: refused:...:stale-after-rebuild
--   3 CURRENT     current stub: green, cargo never called
--   4 UNKNOWN     rc 4 (no checkout above the binary): green, no rebuild
--   5 WIRED       --ci-full calls it before the pre-build gate runs
-- On the pre-fix build.sh there is no block, and the fixture refuses.
--
-- Usage: tillandsias-plan script run scripts/lua/test-ci-full-refreshes-stale-plan-binary.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 30000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("ci-full-refreshes-stale-plan-binary", "not inside a git checkout") end
local ok_read, src = pcall(fs.read, ROOT .. "/build.sh")
if not ok_read then verdict.could_not_run("ci-full-refreshes-stale-plan-binary", "build.sh unreadable") end
local block = src:match("# BEGIN%-PLAN%-BIN%-CURRENT\n(.-)# END%-PLAN%-BIN%-CURRENT")
if not block then
    verdict.emit("refused:ci-full-refreshes-stale-plan-binary:no-block", 1,
        "build.sh has no BEGIN-PLAN-BIN-CURRENT block: --ci-full does not check the plan binary (1925-77h4)")
end

local REL = "target/plan-scratch/ci-full-plan-bin-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

-- arm <name> <initial state: stale|current|unknown> <cargo fixes it?>
local function arm(name, state, fixes)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/ctd/release")
    fs.mkdir(d .. "/bin")
    fs.mkdir(d .. "/root")
    local D = ROOT .. "/" .. d
    fs.write(d .. "/state", state .. "\n")
    -- The stub answers --check from the state file: 0 current, 3 stale, 4 unknown.
    fs.write(d .. "/ctd/release/tillandsias-plan",
        "#!/usr/bin/env bash\nread s < " .. D .. "/state\n" ..
        'case "$s" in current) echo ok:validator-surface:x; exit 0 ;; stale) echo stale:validator-surface >&2; exit 3 ;; *) exit 4 ;; esac\n')
    fs.write(d .. "/bin/cargo", "#!/usr/bin/env bash\necho call >> " .. D .. "/cargo.log\n" ..
        (fixes and ("echo current > " .. D .. "/state\n") or ""))
    run({ "chmod", "+x", D .. "/ctd/release/tillandsias-plan", D .. "/bin/cargo" })
    fs.write(d .. "/run.sh",
        "_afford() { printf '  why: %s\\n  remedy: %s\\n' \"$1\" \"$2\" >&2; }\n" ..
        "SCRIPT_DIR=" .. D .. "/root\nCARGO_TARGET_DIR=" .. D .. "/ctd\nPATH=" .. D .. "/bin:$PATH\n" ..
        block .. "\n_ci_full_plan_bins_current; echo rc=$?\n")
    local r = run({ "bash", D .. "/run.sh" })
    local o = (r.stdout or "") .. (r.stderr or "")
    local calls = 0
    if fs.exists(d .. "/cargo.log") then
        for _ in (fs.read(d .. "/cargo.log")):gmatch("call") do calls = calls + 1 end
    end
    return o, calls
end

local o, calls = arm("rebuilt", "stale", true)
check("1 REBUILT a stale binary is rebuilt once and the run goes on",
    o:find("rc=0", 1, true) and o:find("ok:ci-full-plan-binary:rebuilt:", 1, true) and calls == 1,
    "calls=" .. calls .. "\n" .. o)

o, calls = arm("still", "stale", false)
check("2 STILL-STALE a binary still stale after the rebuild refuses the run",
    o:find("rc=1", 1, true) and o:find("refused:ci-full-plan-binary:stale-after-rebuild:", 1, true)
        and o:find("remedy:", 1, true) and calls == 1,
    "calls=" .. calls .. "\n" .. o)

o, calls = arm("current", "current", false)
check("3 CURRENT a current binary is not rebuilt",
    o:find("rc=0", 1, true) and o:find("ok:ci-full-plan-binary:current:", 1, true) and calls == 0,
    "calls=" .. calls .. "\n" .. o)

o, calls = arm("unknown", "unknown", false)
check("4 UNKNOWN rc 4 is reported, not refused, and triggers no rebuild",
    o:find("rc=0", 1, true) and o:find("note:ci-full-plan-binary:unknown:", 1, true) and calls == 0,
    "calls=" .. calls .. "\n" .. o)

local ci = src:match('_step "Running full CI/CD validation %(pre%-build gate%)%.%.%."(.-)if _run_local_ci_gate')
check("5 WIRED --ci-full calls the check before the pre-build gate",
    ci and ci:find("_ci_full_plan_bins_current || exit 1", 1, true),
    "the --ci-full branch does not call _ci_full_plan_bins_current before _run_local_ci_gate")

run({ "rm", "-rf", W })
if failed == 0 then
    verdict.emit("ok:ci-full-refreshes-stale-plan-binary:" .. passed .. "/" .. passed, 0)
end
verdict.emit("refused:ci-full-refreshes-stale-plan-binary:" .. failed .. "-failed", 1)
