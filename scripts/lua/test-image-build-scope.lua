-- @trace order:1776-d5k2
-- @env PATH HOME TILLANDSIAS_HEADLESS_BIN
--
-- test-image-build-scope.lua — `podman build` runs under a CPU/IO/memory scope
-- (1776-d5k2). Drives the real binary's `--internal-ensure-image <root> web
-- <tag>` with PATH holding only shims: podman, and systemd-run / nice, which
-- each log their own argv and then exec what they wrap.
--   1 SYSTEMD     systemd-run present and its probe succeeds: the build runs
--                 under `systemd-run --user --scope` with CPUWeight, IOWeight
--                 and MemoryHigh
--   2 NICE        no systemd-run on PATH: the build runs under `nice -n 10`
--   3 NO-MANAGER  systemd-run present but its probe fails (a container or a
--                 WSL2 guest): the build falls back to nice
--   4 UNBOUNDED   TILLANDSIAS_IMAGE_BUILD_UNBOUNDED=1: the build runs bare
--                 (NEGATIVE CONTROL for the wrappers' logs)
--
-- The binary is TILLANDSIAS_HEADLESS_BIN, else target/debug/tillandsias.
-- Usage: tillandsias-plan script run scripts/lua/test-image-build-scope.lua

local NAME = "image-build-scope-fixture"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local BIN = env.get("TILLANDSIAS_HEADLESS_BIN")
if not BIN or BIN == "" then BIN = ROOT .. "/target/debug/tillandsias" end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run(NAME, "no headless binary at " .. BIN .. " (cargo build -p tillandsias-headless, or set TILLANDSIAS_HEADLESS_BIN)")
end

local REL = "target/plan-scratch/build-scope-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local D = ROOT .. "/" .. REL

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local PODMAN = [[#!/bin/sh
printf 'podman %s\n' "$*" >> "$SHIM_LOG"
case "$1" in
  build) echo "STEP 1/1: FROM scratch"; echo "COMMIT x"; exit 0;;
  info) echo "$SHIM_GRAPHROOT"; exit 0;;
  image) [ "$2" = exists ] && exit 1; exit 0;;
esac
exit 0
]]
-- Logs, then execs what follows `--`. The probe runs `true`; SHIM_NO_MANAGER
-- makes the probe fail the way a host without a user manager does.
local SYSTEMD_RUN = [[#!/bin/sh
printf 'systemd-run %s\n' "$*" >> "$SHIM_LOG"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
if [ "$1" = true ]; then [ -z "$SHIM_NO_MANAGER" ]; exit $?; fi
exec "$@"
]]
local NICE = [[#!/bin/sh
printf 'nice %s\n' "$*" >> "$SHIM_LOG"
shift 2
exec "$@"
]]

local n = 0
local function run(shims, extra)
    n = n + 1
    local c = D .. "/" .. n
    for _, sub in ipairs({ "bin", "root/images/web", "graph", "cache", "run", "home" }) do fs.mkdir(c .. "/" .. sub) end
    for name, body in pairs(shims) do
        fs.write(c .. "/bin/" .. name, body)
        proc.run({ argv = { "chmod", "+x", c .. "/bin/" .. name }, timeout_ms = 10000 })
    end
    fs.write(c .. "/root/images/web/Containerfile", "FROM scratch\nCOPY a /a\n")
    fs.write(c .. "/root/images/web/a", tostring(n) .. "\n")
    fs.write(c .. "/shim.log", "")
    local e = {
        HOME = c .. "/home", PATH = c .. "/bin",
        XDG_RUNTIME_DIR = c .. "/run", XDG_CACHE_HOME = c .. "/cache",
        SHIM_LOG = c .. "/shim.log", SHIM_GRAPHROOT = c .. "/graph",
        TILLANDSIAS_PODMAN_BIN = c .. "/bin/podman",
        TILLANDSIAS_IMAGE_BUILD_DETACH = "0",
        TILLANDSIAS_IMAGE_DISK_NEED_OVERRIDE = "1",
    }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run({ argv = { BIN, "--internal-ensure-image", c .. "/root", "web", "localhost/tillandsias-web:v0.0.0.1" },
        env = e, timeout_ms = 120000 })
    return r.code or -1, fs.read(c .. "/shim.log") or "", (r.stdout or "") .. (r.stderr or "")
end
-- the wrapper line that ran the build, if any
local function wrapped(log, wrapper)
    for l in log:gmatch("[^\n]+") do
        if l:find("^" .. wrapper .. " ") and l:find("/podman build ", 1, true) then return l end
    end
    return nil
end
local function built(log) return log:find("\npodman build ", 1, true) ~= nil or log:find("^podman build ") ~= nil end

local ALL = { podman = PODMAN, ["systemd-run"] = SYSTEMD_RUN, nice = NICE }

local rc, log, o = run(ALL)
local w = wrapped(log, "systemd%-run")
arm("1 SYSTEMD the build runs under a user scope with CPUWeight, IOWeight and MemoryHigh",
    rc == 0 and built(log) and w ~= nil and w:find("--user --scope", 1, true) ~= nil
    and w:find("CPUWeight=50", 1, true) ~= nil and w:find("IOWeight=50", 1, true) ~= nil
    and w:find("MemoryHigh=%d+") ~= nil, rc .. " " .. log .. " " .. o)

rc, log, o = run({ podman = PODMAN, nice = NICE })
w = wrapped(log, "nice")
arm("2 NICE without systemd-run the build runs under nice -n 10",
    rc == 0 and built(log) and w ~= nil and w:find("^nice %-n 10 ") ~= nil, rc .. " " .. log .. " " .. o)

rc, log, o = run(ALL, { SHIM_NO_MANAGER = "1" })
arm("3 NO-MANAGER systemd-run whose probe fails falls back to nice",
    rc == 0 and built(log) and wrapped(log, "nice") ~= nil and wrapped(log, "systemd%-run") == nil,
    rc .. " " .. log .. " " .. o)

rc, log, o = run(ALL, { TILLANDSIAS_IMAGE_BUILD_UNBOUNDED = "1" })
arm("4 UNBOUNDED the opt-out runs the build bare",
    rc == 0 and built(log) and wrapped(log, "nice") == nil and wrapped(log, "systemd%-run") == nil
    and not log:find("systemd-run", 1, true), rc .. " " .. log .. " " .. o)

proc.run({ argv = { "rm", "-rf", D }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:" .. NAME .. ":" .. #failed .. "-of-4", 1) end
verdict.emit("ok:" .. NAME .. ":4", 0)
