-- @trace order:1931-steb
--
-- test-gate-changed-parallel-fixtures.lua — ./build.sh --changed runs its
-- selected fixtures in a bounded pool (scripts/gate-changed.sh, between
-- BEGIN-FX-POOL / END-FX-POOL). The block runs extracted over stub fixtures:
--   1 PARALLEL  four 1 s fixtures take < 2.5 s at 4 jobs and >= 3 s at 1 job
--   2 ORDER     verdict lines come out in selection order, the same at 1 and
--               4 jobs (ms aside)
--   3 FAILURE   a failing fixture's tail and fail:...:rc=3 are printed and
--               counted; the others still pass
--   4 SERIAL    a fixture declaring `# preflight: serial` runs with no other
--               fixture beside it
--   5 LOGS      each fixture's log holds only its own output
--   6 SELECTION an unselected population row does not run
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-changed-parallel-fixtures.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("gate-changed-parallel-fixtures", "not inside a git checkout") end
local ok_read, src = pcall(fs.read, ROOT .. "/scripts/gate-changed.sh")
if not ok_read then verdict.could_not_run("gate-changed-parallel-fixtures", "gate-changed.sh unreadable") end
local block = src:match("# BEGIN%-FX%-POOL\n(.-)# END%-FX%-POOL")
if not block then
    verdict.emit("refused:gate-changed-parallel-fixtures:no-pool", 1,
        "scripts/gate-changed.sh has no BEGIN-FX-POOL block: --changed runs its fixtures serially (1931-steb)")
end

local REL = "target/plan-scratch/gate-changed-pool-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/root/scripts")
fs.mkdir(REL .. "/running")
local RUN = W .. "/running"
-- Non-serial stubs mark themselves running for their second; the serial stub
-- refuses if any marker is present.
local function sleeper(name, rc, extra)
    return "#!/usr/bin/env bash\n: > " .. RUN .. "/" .. name .. "\necho only-" .. name .. "\n" ..
        (extra or "") .. "sleep 1\nrm -f " .. RUN .. "/" .. name .. "\nexit " .. rc .. "\n"
end
local STUBS = {
    { "a", sleeper("a", 0) },
    { "b", sleeper("b", 0) },
    { "c", sleeper("c", 0) },
    { "d", sleeper("d", 3, "echo boom\n") },
    { "s", "#!/usr/bin/env bash\n# preflight: serial — fixture: asserts it runs alone\necho only-s\n" ..
        'if [ -n "$(ls ' .. RUN .. ')" ]; then echo "not-alone: $(ls ' .. RUN .. ' | tr \'\\n\' \' \')"; exit 9; fi\nexit 0\n' },
    { "u", "#!/usr/bin/env bash\necho ran > " .. W .. "/u-ran\n" },
}
local pop = {}
for _, st in ipairs(STUBS) do
    fs.write(REL .. "/root/scripts/" .. st[1] .. ".sh", st[2])
    pop[#pop + 1] = "id-" .. st[1] .. "\tsh\tscripts/" .. st[1] .. ".sh\t\t0\tstub " .. st[1]
end
local SEL = "id-a\nid-b\nid-c\nid-d\nid-s\n"

local function pool(jobs)
    local d = REL .. "/work-" .. jobs
    fs.mkdir(d)
    local D = ROOT .. "/" .. d
    fs.write(d .. "/pop", table.concat(pop, "\n") .. "\n")
    fs.write(d .. "/fx-sel.ids", SEL)
    fs.write(d .. "/run.sh",
        "ROOT=" .. W .. "/root\nWORK=" .. D .. "\n_plan=\"\"\n_fail=0; _ran=0\nGATE_CHANGED_JOBS=" .. jobs .. "\n" ..
        "_now() { echo $(( $(date +%s%N) / 1000000 )); }\n" ..
        "t0=$(_now)\n" .. block .. "\necho \"summary fail=$_fail ran=$_ran wall=$(( $(_now) - t0 ))\"\n")
    local r = run({ "bash", D .. "/run.sh" })
    return (r.stdout or "") .. (r.stderr or ""), D
end
local function verdicts(o)
    local v = {}
    for line in o:gmatch("[^\n]+") do
        if line:match("^ok:gate%-changed:fixture:") then v[#v + 1] = line:match("^(ok:gate%-changed:fixture:%S+)") end
        if line:match("^fail:gate%-changed:fixture:") then v[#v + 1] = line:match("^(fail:gate%-changed:fixture:%S+ rc=%d+)") end
    end
    return table.concat(v, "|")
end
local function wall(o) return tonumber(o:match("wall=(%d+)") or "0") end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local o4, D4 = pool(4)
local o1 = pool(1)
local want = "ok:gate-changed:fixture:scripts/a.sh|ok:gate-changed:fixture:scripts/b.sh|" ..
    "ok:gate-changed:fixture:scripts/c.sh|fail:gate-changed:fixture:scripts/d.sh rc=3|ok:gate-changed:fixture:scripts/s.sh"

check("1 PARALLEL four 1 s fixtures overlap at 4 jobs and do not at 1",
    wall(o4) < 2500 and wall(o1) >= 3000, "wall at 4 jobs=" .. wall(o4) .. " ms, at 1 job=" .. wall(o1) .. " ms")
check("2 ORDER verdicts in selection order, identical at 1 and 4 jobs",
    verdicts(o4) == want and verdicts(o1) == want, "4 jobs: " .. verdicts(o4) .. "\n1 job: " .. verdicts(o1))
check("3 FAILURE the failing fixture's tail is printed and it is counted once",
    o4:find("boom", 1, true) and o4:find("summary fail=1 ran=5", 1, true), o4)
check("4 SERIAL a serial fixture runs with nothing beside it",
    o4:find("ok:gate-changed:fixture:scripts/s.sh", 1, true) and not o4:find("not-alone", 1, true), o4)
local iso = true
for n, name in ipairs({ "a", "b", "c", "d", "s" }) do
    local okr, log = pcall(fs.read, REL .. "/work-4/fx." .. n .. ".out")
    if not okr then iso = false
    else
        for _, other in ipairs({ "a", "b", "c", "d", "s" }) do
            if other ~= name and log:find("only-" .. other, 1, true) then iso = false end
        end
        if not log:find("only-" .. name, 1, true) then iso = false end
    end
end
check("5 LOGS each fixture's log holds only its own output", iso, "a log was missing or mixed")
check("6 SELECTION an unselected population row does not run", not fs.exists(REL .. "/u-ran"), "u.sh ran")

run({ "rm", "-rf", W })
if failed == 0 then verdict.emit("ok:gate-changed-parallel-fixtures:" .. passed .. "/" .. passed, 0) end
verdict.emit("refused:gate-changed-parallel-fixtures:" .. failed .. "-failed", 1)
