-- @trace order:1776-d5k2
-- @env PATH HOME TILLANDSIAS_HEADLESS_BIN
--
-- test-image-ensure-disk-preflight.lua — an on-demand image build refuses
-- BEFORE it builds when podman's store cannot hold the image (1776-d5k2).
-- Drives the real binary's `--internal-ensure-image <root> web <tag>` against
-- a podman shim that logs every call and answers `info` with a scratch graph
-- root; TILLANDSIAS_IMAGE_DISK_NEED_OVERRIDE is the need seam.
--   1 REFUSE     need = 2^60 bytes: exits non-zero, prints
--                refused:image-ensure:web:disk:<free>MiB/<need>MiB, the shim
--                saw ZERO builds, and no failure marker was written
--   2 BUILDS     NEGATIVE CONTROL: need = 1 byte builds (one `podman build`)
--   3 UNKNOWN    podman cannot say where its store is: the build runs (an
--                unanswered question is not a refusal)
--   4 DETACHED   through the session-detached helper, the caller gets the
--                refusal itself, not "helper exited 1" and a log tail
--
-- The binary is TILLANDSIAS_HEADLESS_BIN, else target/debug/tillandsias.
-- Usage: tillandsias-plan script run scripts/lua/test-image-ensure-disk-preflight.lua

local NAME = "image-ensure-disk-preflight-fixture"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local BIN = env.get("TILLANDSIAS_HEADLESS_BIN")
if not BIN or BIN == "" then BIN = ROOT .. "/target/debug/tillandsias" end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then verdict.could_not_run(NAME, "no headless binary at " .. BIN .. " (cargo build -p tillandsias-headless, or set TILLANDSIAS_HEADLESS_BIN)") end

local REL = "target/plan-scratch/disk-preflight-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
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
  info) [ -n "$SHIM_GRAPHROOT" ] || exit 125; echo "$SHIM_GRAPHROOT"; exit 0;;
  image) [ "$2" = exists ] && exit 1; exit 0;;
esac
exit 0
]]

local n = 0
-- run(need, opts) -> rc, output, shim log, case dir
local function run(need, opts)
    opts = opts or {}
    n = n + 1
    local c = D .. "/" .. n
    for _, sub in ipairs({ "bin", "root/images/web", "graph", "cache", "run", "home" }) do fs.mkdir(c .. "/" .. sub) end
    fs.write(c .. "/bin/podman", PODMAN)
    proc.run({ argv = { "chmod", "+x", c .. "/bin/podman" }, timeout_ms = 10000 })
    fs.write(c .. "/root/images/web/Containerfile", "FROM scratch\nCOPY a /a\n")
    fs.write(c .. "/root/images/web/a", tostring(n) .. "\n")
    fs.write(c .. "/shim.log", "")
    local e = {
        HOME = c .. "/home", PATH = c .. "/bin:/usr/bin:/bin",
        XDG_RUNTIME_DIR = c .. "/run", XDG_CACHE_HOME = c .. "/cache",
        SHIM_LOG = c .. "/shim.log",
        SHIM_GRAPHROOT = opts.no_graph and "" or (c .. "/graph"),
        TILLANDSIAS_PODMAN_BIN = c .. "/bin/podman",
        TILLANDSIAS_IMAGE_BUILD_UNBOUNDED = "1",
        TILLANDSIAS_IMAGE_DISK_NEED_OVERRIDE = need,
    }
    if not opts.detached then e.TILLANDSIAS_IMAGE_BUILD_DETACH = "0" end
    local r = proc.run({ argv = { BIN, "--internal-ensure-image", c .. "/root", "web", "localhost/tillandsias-web:v0.0.0.1" },
        env = e, timeout_ms = 120000 })
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code or -1, o, fs.read(c .. "/shim.log") or "", c
end
local function builds(log)
    local k = 0
    for _ in log:gmatch("podman build ") do k = k + 1 end
    return k
end
local function markers(c)
    local ok, list = pcall(fs.walk, c .. "/cache")
    if not ok or not list then return 0 end
    local k = 0
    for _, f in ipairs(list) do if f:find("image-ensure-failures", 1, true) then k = k + 1 end end
    return k
end

local HUGE = "1152921504606846976"
local rc, o, log, c = run(HUGE)
arm("1 REFUSE a need the store cannot hold refuses before building, naming free and need, with no marker",
    rc ~= 0 and o:find("refused:image%-ensure:web:disk:%d+MiB/%d+MiB") ~= nil
    and builds(log) == 0 and markers(c) == 0, rc .. " builds=" .. builds(log) .. " " .. o)

rc, o, log = run("1")
arm("2 BUILDS NEGATIVE CONTROL: a need of 1 byte builds once",
    rc == 0 and builds(log) == 1 and not o:find("refused:", 1, true), rc .. " builds=" .. builds(log) .. " " .. o)

rc, o, log = run(HUGE, { no_graph = true })
arm("3 UNKNOWN podman cannot name its store: the build runs, nothing is refused",
    rc == 0 and builds(log) == 1, rc .. " builds=" .. builds(log) .. " " .. o)

rc, o, log = run(HUGE, { detached = true })
arm("4 DETACHED the session-detached helper's refusal reaches the caller as itself",
    rc ~= 0 and builds(log) == 0 and o:find("refused:image%-ensure:web:disk:%d+MiB/%d+MiB") ~= nil
    and not o:find("helper for web exited", 1, true), rc .. " builds=" .. builds(log) .. " " .. o)

proc.run({ argv = { "rm", "-rf", D }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:" .. NAME .. ":" .. #failed .. "-of-4", 1) end
verdict.emit("ok:" .. NAME .. ":4", 0)
