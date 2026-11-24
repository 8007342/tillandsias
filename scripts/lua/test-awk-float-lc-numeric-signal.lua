-- @trace order:1587-qqzs, order:2278-x4tw
-- @env PATH
-- preflight: serial — times a 1 s TERM grace, which a guard running beside it can stretch
--
-- test-awk-float-lc-numeric-signal.lua — a TERM cleans up the lcnum mutants before
-- the preflight door's KILL lands, and no mutant is ever in the checkout (2278-x4tw).
--
-- The door (build.sh _pf_run_guard) signals only the guard's pid, since darwin
-- has no setsid: TERM, a 1 s grace polled in tenths, then KILL.
-- scripts/test-awk-float-lc-numeric.sh writes three mutants. They were BESIDE the
-- producers until 2278-x4tw, so a kill that skipped its cleanup leaked them into the
-- checkout, where diff-scoped guards read them as added code; they are now in its
-- own TMPDIR.
--   1 CONTROL  a constructed script with the pre-fix shape (an EXIT trap only,
--              in a shell that ignores TERM, so the KILL always lands) still holds its marker file when
--              TERM arrives, needs the KILL, and leaks. This shows the harness
--              can see a leak.
--   2 REAL     the real script, TERMed while its first producer runs (a sed shim
--              holds it for 5 s once the mutants exist), exits 143 within
--              the grace, without the KILL, and leaves nothing in its TMPDIR.
--              Pre-fix it leaked all three (rc 137) at every kill time measured
--              on 2026-10-11.
--
--   3 CHECKOUT while the mutants exist, and after a KILL that no trap can see, the
--              checkout's status is exactly what it was before the run
--
-- Usage: tillandsias-plan script run scripts/lua/test-awk-float-lc-numeric-signal.lua

local SUBJECT = "scripts/test-awk-float-lc-numeric.sh"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/awklc-signal-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
fs.mkdir(REL .. "/tmp")
local function status()
    return proc.run({ argv = { "git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all" }, timeout_ms = 60000 }).stdout or "?"
end
local BEFORE = status()
local function left_in_tmp() return text.trim(proc.run({ argv = { "ls", "-A", ROOT .. "/" .. REL .. "/tmp" }, timeout_ms = 10000 }).stdout or "?") end

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
    "trap '' TERM",
    ": >\"$MARKER\"",
    "echo \"$$\" >\"$TILLANDSIAS_AWKLC_PIDFILE\"",
    -- DETERMINISTIC, NOT TIMING (#322 was evicted on Linux). A `$(sleep 5)`
    -- deferred the EXIT trap on darwin's bash 3.2, but Linux bash ran it on
    -- TERM and the control did not leak. A plain foreground child does not
    -- leak on darwin either: bash runs the EXIT trap on a fatal TERM. So the
    -- control's shell IGNORES TERM. The door's grace then expires, the KILL
    -- lands, and no trap runs under SIGKILL on any platform. That is the leak
    -- the harness must be able to see.
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
    "[ -f '" .. REAL_PID .. ".ready' ] && sleep 5",
    "PATH='" .. ORIG_PATH .. "' exec sed \"$@\"",
    "",
}, "\n"))
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/bin/sed" }, timeout_ms = 5000 })
local hr, pidr = spawn_until_pidfile({ require("common.fixture").posix_shell(), ROOT .. "/" .. SUBJECT }, REL .. "/real.pid",
    { PATH = ROOT .. "/" .. REL .. "/bin:" .. ORIG_PATH, TMPDIR = ROOT .. "/" .. REL .. "/tmp" })
-- 1612-jp94 (red 3/3 in Windows' WSL builder guest: "no pid file within
-- 10 s"). The subject writes its pid at START and <pid>.ready once its mutants
-- exist, so this waits for an EVENT, not a fixed time: ready, or the subject
-- gone. A subject that ends before its mutants is judged by what it SAID.
local ready, ended = false, false
if pidr then
    for _ = 1, 1200 do
        if fs.exists(REL .. "/real.pid.ready") then ready = true; break end
        if not alive(pidr) then ended = true; break end
        pause("0.1")
    end
end
local SKIPPED
if not pidr then
    hr:kill()
    arm("2 REAL the script started", false, "no pid file within 10 s of spawning it")
elseif not ready then
    local done
    if ended then done = hr:wait() else done = hr:kill() end
    local said = text.trim((type(done) == "table" and done.stdout) or "")
    if said:find("unscoreable:awk-float-lc-numeric:no-comma-locale-on-host", 1, true) then
        -- The host has no comma-decimal locale, so the subject never makes
        -- mutants and there is nothing for a signal to leak. Named, not passed.
        SKIPPED = "no-comma-locale-on-host"
        out.line("skip: 2 REAL the subject reports no comma locale on this host, so it makes no mutants to leak")
    else
        arm("2 REAL the script reached its mutants", false,
            (ended and "it ended first, saying: " or "not ready within 120 s, last said: ") .. said:sub(-300))
    end
else
    pause("1")
    local during, held = status(), left_in_tmp()
    local how, done = door_kill(hr, pidr)
    local left = left_in_tmp()
    local code = (type(done) == "table" and done.code) or "?"
    arm("2 REAL a TERM ends the script within the grace (no KILL needed)", how == "term", "ended by " .. how .. ", code " .. tostring(code))
    arm("2 REAL nothing is left in its TMPDIR, where the mutants were", left == "" and held ~= "", "held [" .. held .. "] left [" .. left .. "]")
    arm("3 CHECKOUT its status did not change while the mutants existed", during == BEFORE, "before [" .. BEFORE .. "] during [" .. during .. "]")
    -- A KILL runs no trap: the mutants leak into TMPDIR (the door deletes a guard's), never here.
    proc.run({ argv = { "rm", "-f", ROOT .. "/" .. REL .. "/real.pid.ready", ROOT .. "/" .. REL .. "/real.pid" }, timeout_ms = 5000 })
    local hk, pidk = spawn_until_pidfile({ require("common.fixture").posix_shell(), ROOT .. "/" .. SUBJECT }, REL .. "/real.pid",
        { PATH = ROOT .. "/" .. REL .. "/bin:" .. ORIG_PATH, TMPDIR = ROOT .. "/" .. REL .. "/tmp" })
    for _ = 1, 1200 do if not pidk or fs.exists(REL .. "/real.pid.ready") or not alive(pidk) then break end pause("0.1") end
    hk:kill()
    local leaked = left_in_tmp()
    arm("3 CHECKOUT a KILL leaks the mutants into TMPDIR and nothing into the checkout",
        leaked ~= "" and status() == BEFORE, "tmp [" .. leaked .. "] status [" .. status() .. "]")
    proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL .. "/tmp" }, timeout_ms = 60000 })
end

if #failed > 0 then
    verdict.emit("violation:awk-float-lc-numeric-signal:" .. #failed .. "-failed", 1)
end
if SKIPPED then verdict.skip("awk-float-lc-numeric-signal", SKIPPED) end
verdict.ok("awk-float-lc-numeric-signal", "5 arms")
