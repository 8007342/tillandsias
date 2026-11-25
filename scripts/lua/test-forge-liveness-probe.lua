-- @trace order:265, order:2341-324y
--
-- test-forge-liveness-probe.lua — scripts/forge-liveness-probe.sh over scratch
-- projects, with no container: a fresh heartbeat is alive (progressing when HEAD
-- moved, quiet when it did not), a stale or missing one is dead_air, the heartbeat
-- deadline and the wall-clock deadline are honoured, and the exit codes follow.
-- Ported from the .sh (2341-324y).
--
-- Verdict: ok:forge-liveness-probe:8 arms | violation:forge-liveness-probe:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-liveness-probe")
local SH = fixture.posix_shell()
local PROBE = fixture.repo_root() .. "/scripts/forge-liveness-probe.sh"
local DROP = { "TILLANDSIAS_*" }
local NOW = os.time()

-- age: seconds since the heartbeat, or nil for no heartbeat file.
local function project(tag, age, with_git)
    local d = with_git and T:git_repo(tag) or T:scratch(tag)
    if age then
        T:must{ "touch", "-t", os.date("!%Y%m%d%H%M.%S", NOW - age), d.abs .. "/.forge-heartbeat", env = { TZ = "UTC0" } }
    end
    return d
end
local function status(d, ...)
    local a = { SH, PROBE, "status", "--project-dir", d.abs, "--heartbeat-file", ".forge-heartbeat", "--no-container",
        "--start-time", tostring(NOW), env_unset = DROP, timeout_ms = 30000 }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    local r = T:run(a)
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function arm(name, want, want_rc, d, ...)
    local c, s, e = status(d, ...)
    T:arm(name, c == want_rc and s == want, "state=" .. s .. " exit=" .. tostring(c) .. " " .. e)
end
local function head(d) return (text.trim(T:must{ "git", "-C", d.abs, "rev-parse", "HEAD" }.stdout or "")) end

arm("1 fresh heartbeat and a moved HEAD: alive_progressing", "alive_progressing", 0, project("p1", 0, true),
    "--before-head", "deadbeef00000000000000000000000000000000")
local quiet = project("p2", 0, true)
arm("2 fresh heartbeat and the same HEAD: alive_quiet", "alive_quiet", 0, quiet, "--before-head", head(quiet))
arm("3 a heartbeat 200s old: dead_air", "dead_air", 1, project("p3", 200, false))
arm("4 no heartbeat file: dead_air", "dead_air", 1, project("p4", nil, false))

local r = T:run{ SH, PROBE, "deadline", "--budget", "5400", "--start-time", tostring(NOW), env_unset = DROP, timeout_ms = 30000 }
local want = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW + 5400)
T:arm("5 the wall-clock deadline is start plus budget", r.code == 0 and text.trim(r.stdout or "") == want, text.trim(r.stdout or "") .. " want " .. want)

-- 200s is past the default 120s (arm 3) and inside a 300s deadline.
local long = project("p6", 200, true)
arm("6 a longer heartbeat deadline keeps a 200s-old heartbeat alive", "alive_progressing", 0, long, "--heartbeat-deadline", "300", "--before-head", "deadbeef")
arm("7 CONTROL the same project past the default deadline is dead", "dead_air", 1, long, "--before-head", "deadbeef")
local u = T:run{ SH, PROBE, env_unset = DROP, timeout_ms = 30000 }
T:arm("8 no mode is a usage error (2), not a dead forge (1)", u.code == 2, "exit=" .. tostring(u.code))
T:finish()
