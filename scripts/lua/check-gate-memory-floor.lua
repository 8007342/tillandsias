-- @env PWD
-- @env TILLANDSIAS_GATE_MEMORY_FLOOR_MB
-- @env TILLANDSIAS_GATE_MEMORY_OSRELEASE
-- @trace order:1176-fn2p, order:1047-h88p, order:1337-7jr5, order:1354-apns, order:2167-gmfl
--
-- check-gate-memory-floor.lua — refuse a gate BY NAME on a host with too little
-- memory to start it, instead of letting it be SIGKILLed minutes later with a
-- log that ends mid-line. (Ported from scripts/check-gate-memory-floor.sh, the
-- shell-to-lua item carried by order 2167-gmfl. That path is now a bootstrap
-- that execs this file when a plan binary resolves and otherwise names its
-- could-not-run; the design — a LEGIBILITY floor, not a capacity predictor;
-- MemAvailable, not MemTotal; why a WSL2 guest refuses to assert; why each
-- could-not-run also ends on a skip: line — is told in
-- `git log -p -- scripts/check-gate-memory-floor.sh`.)
--
-- Same verdicts and exit codes as the .sh:
--   ok:gate-memory:<n>MB available, floor <f>MB                               0
--   refused:gate:insufficient-memory (<n>MB available, floor <f>MB — read from <file>)   1
--   could-not-run:gate-memory:<why> + skip:gate-memory:<why>                    3
--   usage                                                                       2
--
-- /proc and the fixtures' meminfo files lie outside the repository, so they are
-- read through a child `cat`, not fs.* (confined to the runner's root).

local function caller_dir()
    local d = env.get("PWD")
    if d ~= nil and d ~= "" and (d:sub(1, 1) == "/" or d:match("^%a:[/\\]")) then return d end
    return nil
end
local CALLER = caller_dir()

local function read_file(p)
    local r = proc.run({ argv = { "cat", p }, cwd = CALLER, timeout_ms = 10000 })
    if r.status == "exited" and r.code == 0 then return r.stdout or "" end
    return nil
end

-- Two lines, the second a terminal skip: (1354-apns: the readers know one word
-- for "nothing was asserted", and could-not-run is not it).
local function cannot(why, reason)
    out.line("could-not-run:gate-memory:" .. why)
    verdict.emit("skip:gate-memory:" .. reason, 3)
end

local FLOOR_MB = env.get("TILLANDSIAS_GATE_MEMORY_FLOOR_MB")
if FLOOR_MB == nil or FLOOR_MB == "" then FLOOR_MB = "1024" end
local MEMINFO, EXPLICIT = "/proc/meminfo", false
local OSRELEASE = env.get("TILLANDSIAS_GATE_MEMORY_OSRELEASE")
if OSRELEASE == nil or OSRELEASE == "" then OSRELEASE = "/proc/sys/kernel/osrelease" end

local i = 1
while arg[i] ~= nil do
    local a = arg[i]
    if a == "--meminfo-from" then MEMINFO = arg[i + 1] or ""; EXPLICIT = true; i = i + 2
    elseif a == "--floor-mb" then FLOOR_MB = arg[i + 1] or ""; i = i + 2
    else
        verdict.emit("blocked:gate-memory:usage", 2,
            "usage: check-gate-memory-floor.sh [--meminfo-from FILE] [--floor-mb N]")
    end
end

if not FLOOR_MB:match("^%d+$") then
    cannot("bad-floor:" .. FLOOR_MB .. " (TILLANDSIAS_GATE_MEMORY_FLOOR_MB must be an integer in MB)", "bad-floor")
end
local floor = tonumber(FLOOR_MB)

-- 1337-7jr5: inside a WSL2 guest /proc/meminfo is the utility VM's, not the
-- Windows host's that reaps the gate. Only the DEFAULT read refuses to assert.
if not EXPLICIT then
    local rel = read_file(OSRELEASE)
    if rel ~= nil and rel:find("WSL2", 1, true) then
        cannot("wsl2-guest-meminfo-is-not-the-host (this is a WSL2 guest; its /proc/meminfo is the utility VM's, not the Windows host's that reaps the gate. Pass the host figure with --meminfo-from to assert)",
            "wsl2-guest")
    end
end

local info = read_file(MEMINFO)
if info == nil then
    cannot("no-meminfo:" .. MEMINFO .. " (this host exposes no readable MemAvailable; nothing is asserted about its memory)",
        "no-meminfo")
end

local avail_kb = nil
for line in (info .. "\n"):gmatch("([^\n]*)\n") do
    local kb = line:match("^MemAvailable:%s*(%d+)%s*kB")
    if kb then avail_kb = tonumber(kb); break end
end
if avail_kb == nil then
    -- MemFree under-reports by the reclaimable page cache; refusing to guess is right.
    cannot("no-memavailable (read " .. MEMINFO .. " but it carries no MemAvailable line; MemFree is not a substitute and would under-report)",
        "no-memavailable")
end

local avail_mb = avail_kb // 1024

if avail_mb < floor then
    verdict.emit("refused:gate:insufficient-memory (" .. avail_mb .. "MB available, floor " .. floor
        .. "MB — read from " .. MEMINFO .. ")", 1, table.concat({
        "  The expensive phases would very likely be SIGKILLed partway with no verdict,",
        "  which is indistinguishable from a hang (1176-fn2p). Refusing in seconds instead.",
        "  This is a LEGIBILITY floor, not a capacity claim: a host above it is never refused here.",
        "  Raise or lower it deliberately with TILLANDSIAS_GATE_MEMORY_FLOOR_MB.",
        "  why: " .. avail_mb .. "MB is available against a " .. floor .. "MB floor, so the gate would likely be killed without a verdict",
        "  remedy: free memory (stop other gates, VMs or browsers on this host) and re-run; change TILLANDSIAS_GATE_MEMORY_FLOOR_MB only deliberately",
    }, "\n"))
end

verdict.emit("ok:gate-memory:" .. avail_mb .. "MB available, floor " .. floor .. "MB", 0)
