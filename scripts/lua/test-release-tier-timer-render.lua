-- @trace order:890-27mv, order:1174-6r4k, order:2303-rttr
-- @env PATH
--
-- test-release-tier-timer-render.lua — does the release-tier installer render a
-- unit that answers the question the release actually gates on?
-- Ported from test-release-tier-timer-render.sh (2303-rttr).
--
-- REGIME: HERMETIC, and it ARMS NOTHING. XDG_CONFIG_HOME is a scratch dir, and
-- a STUB systemctl leads PATH: it answers show-environment and daemon-reload,
-- logs every call, and REFUSES `enable`, so the installer stops before
-- arming a timer or touching loginctl. The .sh relied on the real systemctl
-- failing to find the sandboxed unit; on a host with no systemd (darwin) the
-- installer refused with no-systemctl before rendering, and 6 of 8 arms read
-- red on trunk (2303-rttr). The stub makes the render reachable on every host
-- and the "armed nothing" claim hold by construction, not by luck.
--
--   1 both units render into the sandbox
--   2 THE LOAD-BEARING ONE: ExecStart runs local-ci.sh with NO --phase (1174-6r4k)
--   3 the timer carries a schedule directive
--   4 --interval reaches the rendered unit
--   5 negative control: no @PLACEHOLDER@ survives (premise first: units exist)
--   6 negative control: a template with an unknown placeholder is refused
--   7 a refused render leaves no unit behind
--   8 the installer reached the STUB's enable (so no real systemctl was asked)
--   9 this host's real systemd, if any, knows no tillandsias-release-tier unit
--
-- GRAMMAR ok:release-tier-timer-render:9 arms | violation:release-tier-timer-render:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("release-tier-timer-render")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()

local function stub_env(dir)
    fs.write(dir.rel .. "/bin/systemctl",
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$STUB_LOG\"\n"
        .. "case \" $* \" in *' enable '*) exit 1 ;; esac\nexit 0\n")
    T:must{ "chmod", "+x", dir.abs .. "/bin/systemctl" }
    local path = env.get("PATH") or "/usr/bin:/bin"
    return { XDG_CONFIG_HOME = dir.abs .. "/cfg", STUB_LOG = dir.abs .. "/systemctl.log",
             PATH = dir.abs .. "/bin:" .. path }
end
local function read(p)
    local r = proc.run{ argv = { "cat", p } }
    if r.code ~= 0 then return nil end
    return r.stdout or ""
end
local function install(dir, installer, ...)
    local r = proc.run{ argv = { SH, installer, ... }, env = stub_env(dir), timeout_ms = 60000 }
    local lines = text.lines(text.trim(r.stdout or ""))
    return lines[#lines] or ""
end

-- 1-5, 8: the real installer, rendered into a sandbox.
local S = T:scratch("render")
fs.mkdir(S.rel .. "/bin")
local v = install(S, ROOT .. "/scripts/install-release-tier-timer.sh",
    "--interval", "24h", "--boot-delay", "45min", "--timeout", "180m")
local units = S.abs .. "/cfg/systemd/user"
local svc = read(units .. "/tillandsias-release-tier.service")
local tmr = read(units .. "/tillandsias-release-tier.timer")
T:arm("1 both units render", svc ~= nil and tmr ~= nil, "missing under " .. units .. " (installer said " .. v .. ")")

local exec_line = (svc or ""):match("\nExecStart=[^\n]*") or ((svc or ""):match("^ExecStart=[^\n]*"))
exec_line = exec_line and text.trim(exec_line) or ""
T:arm("2 the service runs local-ci.sh with no --phase (a full-tier answer)",
    exec_line:find("local-ci.sh", 1, true) ~= nil and exec_line:find("--phase", 1, true) == nil,
    "ExecStart: " .. (exec_line ~= "" and exec_line or "<absent>"))

local sched = 0
for _, l in ipairs(text.lines(tmr or "")) do
    for _, d in ipairs({ "OnCalendar", "OnUnitInactiveSec", "OnUnitActiveSec", "OnBootSec", "OnActiveSec" }) do
        if l:sub(1, #d + 1) == d .. "=" then sched = sched + 1 end
    end
end
T:arm("3 the timer carries at least one schedule directive", sched >= 1, "no recognised schedule directive")

local has_interval = false
for _, l in ipairs(text.lines(tmr or "")) do if l == "OnUnitInactiveSec=24h" then has_interval = true end end
T:arm("4 --interval reaches the unit", has_interval, "OnUnitInactiveSec=24h not found in the rendered timer")

local left = (svc or ""):match("@[A-Z]*@") or (tmr or ""):match("@[A-Z]*@")
T:arm("5 no placeholder survives the render", svc ~= nil and tmr ~= nil and left == nil,
    (svc == nil or tmr == nil) and "cannot tell: the units were never rendered" or ("placeholder left: " .. tostring(left)))

local log = read(S.abs .. "/systemctl.log") or ""
T:arm("8 the installer reached the stub's enable, so no real systemctl was asked",
    v == "fail:install:enable-timer" and log:find("enable", 1, true) ~= nil,
    "verdict=" .. v .. " stub log=[" .. log:gsub("\n", " | ") .. "]")

-- 6-7: a drifted template copy.
local D = T:scratch("drift")
fs.mkdir(D.rel .. "/bin")
T:must{ "cp", "-R", ROOT .. "/packaging", D.abs .. "/packaging" }
T:must{ "mkdir", "-p", D.abs .. "/scripts" }
T:must{ "cp", ROOT .. "/scripts/install-release-tier-timer.sh", D.abs .. "/scripts/" }
local tin = D.rel .. "/packaging/systemd/user/tillandsias-release-tier.timer.in"
fs.write(tin, fs.read(tin) .. "\n# @NOSUCHTOKEN@\n")
local dv = install(D, D.abs .. "/scripts/install-release-tier-timer.sh")
T:arm("6 an unsubstituted placeholder is refused", dv == "fail:install:unsubstituted-placeholder", "got: " .. dv)
T:arm("7 a refused render leaves no unit behind",
    proc.run{ argv = { "test", "-e", D.abs .. "/cfg/systemd/user/tillandsias-release-tier.timer" } }.code ~= 0,
    "the timer file survived the refusal")

-- 9: the real user session, when this host has one.
local real = fixture.which("systemctl")
if not real or real == "" then
    T:arm("9 no systemd on this host: nothing could be armed", true)
else
    local r = proc.run{ argv = { real, "--user", "list-unit-files" }, timeout_ms = 30000 }
    T:arm("9 the fixture armed nothing on this host",
        not (r.stdout or ""):find("tillandsias-release-tier", 1, true),
        "tillandsias-release-tier is known to the real user session")
end

T:finish()
