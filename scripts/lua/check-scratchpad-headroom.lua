-- @env TILLANDSIAS_SCRATCHPAD_DIR TMPDIR TILLANDSIAS_SCRATCH_NEED_MB TILLANDSIAS_HEADROOM_QUOTA_BIN TILLANDSIAS_HEADROOM_DF_BIN
-- @trace order:915-wkm2, order:1738-wqmt
--
-- check-scratchpad-headroom.lua — report SCRATCHPAD QUOTA HEADROOM, not
-- filesystem free space. Ported from scripts/check-scratchpad-headroom.sh, the
-- shell-to-lua item the 1738-wqmt installer change carried; same rule and
-- threshold. ONE grammar change, forced by the runner: `script run` verdicts
-- have no `warn:` class, so the two low-headroom verdicts are `degraded:`
-- (still exit 0).
--
-- THE TRAP THIS EXISTS FOR. The agent scratchpad lives on tmpfs. systemd sizes
-- /tmp at 50% of RAM, but a usrquota can sit far below that — so `df` reports
-- gigabytes free while every write returns EDQUOT. The host stays healthy and
-- only the agent's tooling dies, which presents as "my shell is broken" rather
-- than "I filled a disk".
--
-- MEASURED on two hosts 2026-08-26, and the spread is why this check is not a
-- percentage:
--
--   macuahuitl  quota 25564 MB (24.96 GiB)   df size 32 GB
--   lenovinha   quota  5525 MB ( 5.4 GiB)    df size 6.8 GB, "5.2G avail"
--
-- A 4.6x spread in the limit. A percentage threshold tuned to one host is wrong
-- on the other, so the threshold here is ABSOLUTE and derived from what the work
-- actually costs: one cold Rust `target/` was measured at 2.6-4.4 GB. If less
-- than that fits, a build in the scratchpad cannot succeed — whatever percentage
-- it represents.
--
-- ADVISORY, NEVER A GATE. A cycle must not fail because a host is low on scratch;
-- it must be TOLD, early, while it can still choose where to build. A check that
-- red-lights the gate for a capacity condition is the 888-miiy shape. Every
-- verdict exits 0.
--
-- Seams (scripts/lua/test-scratchpad-headroom.lua): TILLANDSIAS_HEADROOM_QUOTA_BIN
-- and TILLANDSIAS_HEADROOM_DF_BIN name the `quota` and `df` to run; the value
-- `absent` means "this host has no such tool". The shell version stubbed them
-- on PATH, which could not hide a system binary (its own fixture's first bug).
--
-- Verdict grammar, one line, matching
--   ^(ok:scratchpad-headroom:[0-9]+m-of-[0-9]+m|degraded:scratchpad-headroom-low:[0-9]+m-of-[0-9]+m|degraded:scratchpad-disk-low:[0-9]+m|skip:(no-quota|no-scratchpad|no-quota-tool))$

local function getenv(name)
    local v = env.get(name)
    if v == nil or v == "" then return nil end
    return v
end

local SCRATCH = getenv("TILLANDSIAS_SCRATCHPAD_DIR") or getenv("TMPDIR") or "/tmp"
-- One cold Rust target/, the largest observed (macuahuitl 2026-08-26).
-- Overridable so a host with a different build profile can calibrate.
local NEED_MB = tonumber(getenv("TILLANDSIAS_SCRATCH_NEED_MB") or "") or 4500
local QUOTA = getenv("TILLANDSIAS_HEADROOM_QUOTA_BIN") or "quota"
local DF = getenv("TILLANDSIAS_HEADROOM_DF_BIN") or "df"

local function note(s) io.stderr:write(s .. "\n") end

-- A directory exists when `test -d` says so: fs.exists is repo-scoped and the
-- scratchpad is outside the repo.
local d = proc.run({ argv = { "test", "-d", SCRATCH }, timeout_ms = 5000 })
if not (d.status == "exited" and d.code == 0) then
    verdict.emit("skip:no-scratchpad", 0)
end

-- Run a tool; nil when it is absent (the seam's `absent`, or no such binary).
local function tool(bin, args)
    if bin == "absent" then return nil end
    local argv = { bin }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 15000 })
    if r.status == "spawn_failed" then return nil end
    return r.stdout or ""
end

-- 88K / 1620M / 3.2G / plain 1K-blocks -> integer MB.
local function to_mb(s)
    s = s or ""
    local n, unit = string.match(s, "^([%d%.]+)([KkMmGgTt]?)$")
    n = tonumber(n or "")
    if n == nil then return 0 end
    unit = string.lower(unit)
    if unit == "k" then return math.floor(n / 1024)
    elseif unit == "m" then return math.floor(n)
    elseif unit == "g" then return math.floor(n * 1024)
    elseif unit == "t" then return math.floor(n * 1048576)
    elseif string.find(s, "%.") then return 0
    else return math.floor(n / 1024) end
end

-- `df -Pm <dir>`: the Available column of the second line, or nil.
local function df_avail()
    local o = tool(DF, { "-Pm", SCRATCH })
    if o == nil then return nil end
    local ls = text.lines(o)
    if #ls < 2 then return nil end
    local f = {}
    for w in string.gmatch(ls[2], "%S+") do f[#f + 1] = w end
    return tonumber(f[4] or "")
end

local q = tool(QUOTA, { "-s", "-f", SCRATCH })
if q == nil then
    -- No quota tooling (macOS, most Windows lanes). Fall back to the filesystem,
    -- and SAY it is the filesystem — reporting a df number as a quota headroom
    -- would be the misattribution this packet's sibling cheatsheet is about.
    local avail = df_avail()
    if avail == nil then verdict.emit("skip:no-quota-tool", 0) end
    if avail < NEED_MB then
        note("[check-scratchpad-headroom] " .. avail .. "M free on " .. SCRATCH .. ", below the " .. NEED_MB .. "M a cold Rust target/ needs.")
        note("[check-scratchpad-headroom] No quota tooling here, so this is FILESYSTEM free space, not a quota headroom.")
        verdict.emit("degraded:scratchpad-disk-low:" .. avail .. "m", 0)
    end
    verdict.emit("skip:no-quota-tool", 0)
end

-- `quota -f <path>` disambiguates: a bare `quota -s` prints one row per tmpfs
-- mount and they are ALL named "tmpfs", so parsing by device name picks an
-- arbitrary one. Measured on lenovinha: /dev/shm, /run/user/1000 and /tmp all
-- report as "tmpfs" and only one of them is the scratchpad. The first data row
-- (after two header lines) with at least four fields: space, then limit.
local used, limit
for i, l in ipairs(text.lines(q)) do
    if i > 2 then
        local f = {}
        for w in string.gmatch(l, "%S+") do f[#f + 1] = w end
        if #f >= 4 then used, limit = to_mb(f[2]), to_mb(f[4]); break end
    end
end
if used == nil or limit <= 0 then verdict.emit("skip:no-quota", 0) end
local avail = math.max(limit - used, 0)

if avail < NEED_MB then
    local dfa = df_avail()
    note("[check-scratchpad-headroom] SCRATCHPAD QUOTA HEADROOM IS " .. avail .. "M of " .. limit .. "M.")
    note("  A cold Rust target/ needs ~" .. NEED_MB .. "M (measured 2.6-4.4 GB), so a build")
    note("  here cannot succeed. Build in the checkout instead — never in the")
    note("  scratchpad (order 915-wkm2).")
    if dfa ~= nil and dfa > avail then
        note("  NOTE: df reports " .. dfa .. "M free, which OVERSTATES what you can use.")
        note("  The quota binds first; df cannot see it. That gap is the whole trap.")
    end
    verdict.emit("degraded:scratchpad-headroom-low:" .. avail .. "m-of-" .. limit .. "m", 0)
end
verdict.emit("ok:scratchpad-headroom:" .. avail .. "m-of-" .. limit .. "m", 0)
