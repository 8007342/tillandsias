-- @trace order:1587-qqzs
-- @env PATH
--
-- test-awk-float-lc-numeric-signal.lua — a TERM must clean up the lcnum mutants
-- before the preflight door's KILL lands.
--
-- The door (build.sh _pf_run_guard) signals only the guard's pid, since darwin
-- has no setsid: TERM, a 1 s grace polled in tenths, then KILL.
-- scripts/test-awk-float-lc-numeric.sh writes three mutants BESIDE the
-- producers it copies (scripts/.mutant-lcnum-*), so a kill that skips its
-- cleanup leaks them into the checkout, where diff-scoped guards read them as
-- added code.
--   1 CONTROL  a constructed script with the pre-fix shape (an EXIT trap only,
--              and a long foreground $(...)) still holds its marker file when
--              TERM arrives, needs the KILL, and leaks. This shows the harness
--              can see a leak.
--   2 REAL     the real script, TERMed while its first producer runs (a sed shim
--              holds it for 5 s once the mutants exist), exits 143 within
--              the grace, without the KILL, and leaves no .mutant-lcnum-* file.
--              Pre-fix it leaked all three (rc 137) at every kill time measured
--              on 2026-10-11.
--
-- Usage: tillandsias-plan script run scripts/lua/test-awk-float-lc-numeric-signal.lua

local SUBJECT = "scripts/test-awk-float-lc-numeric.sh"
local MUTANTS = {
    "scripts/.mutant-lcnum-freshness-inventory.sh",
    "scripts/.mutant-lcnum-select-work-batch.sh",
    "scripts/refusal-calibration/.mutant-lcnum-measure-bands.sh",
}
for _, m in ipairs(MUTANTS) do
    if fs.exists(m) then
        verdict.could_not_run("awk-float-lc-numeric-signal", m .. " already exists before the run, so a leak could not be told from it; delete it and re-run")
    end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/awklc-signal-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local function pause(sec) proc.run({ argv = { "sleep", sec }, timeout_ms = 30000 }) end
local function alive(pid)
    local r = proc.run({ argv = { "kill", "-0", pid }, timeout_ms = 5000 })
    return r.status == "exited" and r.code == 0
end
local function read_pid(path)
    local ok, s = pcall(fs.read, path)
    if ok then return s:match("(%d+)") end
    return nil
end

-- The door's sequence on one pid: TERM, up to 10 x 0.1 s for it to go, then KILL.
-- Returns how it ended ("term" or "kill") and the handle's completion.
local function door_kill(handle, pid)
    proc.run({ argv = { "kill", "-TERM", pid }, timeout_ms = 5000 })
    for _ = 1, 10 do
        if not alive(pid) then return "term", handle:wait() end
        pause("0.1")
    end
    return "kill", handle:kill()
end

local function spawn_until_pidfile(argv, pidfile, extra_env)
    local e = { TILLANDSIAS_AWKLC_PIDFILE = ROOT .. "/" .. pidfile }
    for k, v in pairs(extra_env or {}) do e[k] = v end
    local h = proc.spawn({ argv = argv, cwd = ROOT, env = e, timeout_ms = 120000 })
    for _ = 1, 100 do
        local pid = read_pid(pidfile)
        if pid then return h, pid end
        pause("0.1")
    end
    return h, nil
end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- 1 CONTROL: the pre-fix shape, constructed.
local marker = REL .. "/control-marker"
fs.write(REL .. "/control.sh", table.concat({
    "set -u",
    "trap 'rm -f \"$MARKER\"' EXIT",
    ": >\"$MARKER\"",
    "echo \"$$\" >\"$TILLANDSIAS_AWKLC_PIDFILE\"",
    "v=\"$(sleep 5)\"",
    "",
}, "\n"))
local hc, pidc = spawn_until_pidfile({ "env", "MARKER=" .. ROOT .. "/" .. marker, "bash", ROOT .. "/" .. REL .. "/control.sh" }, REL .. "/control.pid")
if not pidc then
    hc:kill()
    arm("1 CONTROL the constructed script started", false, "no pid file within 10 s")
else
    local how = door_kill(hc, pidc)
    arm("1 CONTROL a deferred EXIT trap leaks under the door's kill (the harness can see a leak)",
        how == "kill" and fs.exists(marker), "ended by " .. how .. ", marker present=" .. tostring(fs.exists(marker)))
end

-- 2 REAL: the real script, TERMed while its first producer runs.
-- A TERM that lands BETWEEN commands runs even a pre-fix EXIT trap at once
-- (measured clean at t=7s), and how long a producer takes depends on the host
-- and on whether select-work-batch finds a plan binary. So the window is made
-- deterministic: a `sed` first on PATH sleeps 5 s once the pid file exists.
-- The producers' pipelines call sed; the script's own shell does not between
-- the pid file and the first producer, and make_mutant's sed runs before the
-- pid file.
local REAL_PID = ROOT .. "/" .. REL .. "/real.pid"
local ORIG_PATH = env.get("PATH") or "/usr/bin:/bin"
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/sed", table.concat({
    "#!/bin/sh",
    "[ -f '" .. REAL_PID .. "' ] && sleep 5",
    "PATH='" .. ORIG_PATH .. "' exec sed \"$@\"",
    "",
}, "\n"))
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/bin/sed" }, timeout_ms = 5000 })
local hr, pidr = spawn_until_pidfile({ "bash", ROOT .. "/" .. SUBJECT }, REL .. "/real.pid",
    { PATH = ROOT .. "/" .. REL .. "/bin:" .. ORIG_PATH })
if not pidr then
    hr:kill()
    arm("2 REAL the script reached its mutants", false, "no pid file within 10 s")
else
    pause("1")
    local how, done = door_kill(hr, pidr)
    local left = {}
    for _, m in ipairs(MUTANTS) do if fs.exists(m) then left[#left + 1] = m end end
    local code = (type(done) == "table" and done.code) or "?"
    arm("2 REAL a TERM ends the script within the grace (no KILL needed)", how == "term", "ended by " .. how .. ", code " .. tostring(code))
    arm("2 REAL no .mutant-lcnum-* file is left in the checkout", #left == 0, table.concat(left, " "))
    for _, m in ipairs(left) do proc.run({ argv = { "rm", "-f", ROOT .. "/" .. m }, timeout_ms = 5000 }) end
end

if #failed > 0 then
    verdict.emit("violation:awk-float-lc-numeric-signal:" .. #failed .. "-failed", 1)
end
verdict.ok("awk-float-lc-numeric-signal", "3 arms")
