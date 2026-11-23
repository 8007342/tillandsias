-- @trace order:2118-tpmy, spec:ci-release
-- @env TILLANDSIAS_HOST_DOOR_MEMINFO TILLANDSIAS_HOST_DOOR_TMP_DIR TILLANDSIAS_HOST_DOOR_TARGET_DIR TILLANDSIAS_HOST_DOOR_ROOT TILLANDSIAS_HOST_DOOR_DISK_GB TILLANDSIAS_HOST_DOOR_TMP_GB TILLANDSIAS_HOST_DOOR_SWAP_FREE_PCT TILLANDSIAS_HOST_DOOR_REQUIRE_SIDECAR PATH
--
-- land-queue-host-door.lua — is THIS HOST fit to gate a candidate?
--
-- Operator 2026-11-20 (landing-pipeline redesign P11): reds that came from the
-- host were read as reds of the candidate and evicted it. Each one cost a gate
-- and a diagnosis: a stale plan binary, a missing staged sidecar in a fresh
-- tree, old worktrees filling the disk, /tmp tmpfs full (macuahuitl: 22 of 32
-- GB), the host deep in swap. The queue asks this door before every candidate.
-- A refusal is could-not-run:host:<cause> — about the host, never the
-- candidate — so the queue evicts NOBODY for it and goes on to the next.
-- (The plan binary is refreshed by the queue itself, PLAN_REFRESH, and
-- reports could-not-run:host:plan-binary-stale from there.)
--
-- Checks, in order; the first that fails is the verdict:
--   sidecar-missing   images/router/tillandsias-router-sidecar is not staged
--                     (Linux; TILLANDSIAS_HOST_DOOR_REQUIRE_SIDECAR=0 skips)
--   stale-worktrees   git worktree list names a prunable worktree
--   disk-low          the target dir's filesystem has < DISK_GB free (default 40)
--   tmp-low           /tmp (TMP_DIR) has < TMP_GB free (default 2)
--   swap-low          swap is configured and < SWAP_FREE_PCT is free (default 25)
-- Every input can be pointed elsewhere by the variables above (the fixture's
-- seams); every default is the production value.
--
-- Usage: tillandsias-plan script run scripts/lua/land-queue-host-door.lua
-- Verdict (stdout, one line):
--   ok:host-door:disk=<g>G tmp=<g>G swap-free=<p>%     exit 0
--   could-not-run:host:<cause>:<detail>                 exit 3

local function getenv(k, dflt)
    local v = env.get(k)
    if v == nil or v == "" then return dflt end
    return v
end

local ROOT = getenv("TILLANDSIAS_HOST_DOOR_ROOT", ".")
local TARGET = getenv("TILLANDSIAS_HOST_DOOR_TARGET_DIR", ROOT .. "/target")
local TMPD = getenv("TILLANDSIAS_HOST_DOOR_TMP_DIR", "/tmp")
local MEMINFO = getenv("TILLANDSIAS_HOST_DOOR_MEMINFO", "/proc/meminfo")
local DISK_GB = tonumber(getenv("TILLANDSIAS_HOST_DOOR_DISK_GB", "40"))
local TMP_GB = tonumber(getenv("TILLANDSIAS_HOST_DOOR_TMP_GB", "2"))
local SWAP_PCT = tonumber(getenv("TILLANDSIAS_HOST_DOOR_SWAP_FREE_PCT", "25"))
local REQUIRE_SIDECAR = getenv("TILLANDSIAS_HOST_DOOR_REQUIRE_SIDECAR", "1") ~= "0"

local function refuse(cause, detail)
    verdict.emit("could-not-run:host:" .. cause .. ":" .. detail, 3)
end

local function run(argv)
    local r = proc.run{ argv = argv, timeout_ms = 30000 }
    return r.code == 0, r.stdout or "", r.stderr or ""
end

-- free GiB on the filesystem holding `dir` (df -Pk: POSIX, kB blocks)
local function free_gb(dir)
    local ok, out = run{ "df", "-Pk", dir }
    if not ok then return nil end
    local avail
    for l in out:gmatch("[^\n]+") do
        local a = l:match("^%S+%s+%d+%s+%d+%s+(%d+)%s+")
        if a then avail = tonumber(a) end
    end
    return avail and (avail / 1048576) or nil
end

-- 1. the router sidecar a fresh tree's gate needs
if REQUIRE_SIDECAR and not fs.exists(ROOT .. "/images/router/tillandsias-router-sidecar") then
    local is_linux = run{ "uname", "-s" }
    local _, os = run{ "uname", "-s" }
    if is_linux and text.trim(os) == "Linux" then
        refuse("sidecar-missing", "images/router/tillandsias-router-sidecar is not staged; remedy: bash scripts/build-sidecar.sh")
    end
end

-- 2. worktrees git already knows are gone
do
    local ok, out = run{ "git", "-C", ROOT, "worktree", "list", "--porcelain" }
    if ok then
        local n = 0
        for _ in out:gmatch("\nprunable[^\n]*") do n = n + 1 end
        if out:match("^prunable") then n = n + 1 end
        if n > 0 then
            refuse("stale-worktrees", n .. " prunable worktree(s); remedy: git worktree prune")
        end
    end
end

-- 3. disk under the target dir (gate worktrees build 20-30 GB each)
-- a fresh checkout has no target/ yet: measure the filesystem it will be made on
if not fs.exists(TARGET) then TARGET = ROOT end
local disk = free_gb(TARGET)
if disk == nil then refuse("disk-unreadable", "df could not read " .. TARGET) end
if disk < DISK_GB then
    refuse("disk-low", string.format("%.1fG free under %s, floor %dG; remedy: remove landed rows' target/work worktrees", disk, TARGET, DISK_GB))
end

-- 4. /tmp (a tmpfs on Silverblue: a full one pushes the host into swap)
local tmpfree = free_gb(TMPD)
if tmpfree == nil then refuse("tmp-unreadable", "df could not read " .. TMPD) end
if tmpfree < TMP_GB then
    refuse("tmp-low", string.format("%.1fG free in %s, floor %dG; remedy: clear stale tillandsias-* entries", tmpfree, TMPD, TMP_GB))
end

-- 5. swap
local ok_m, mem = run{ "cat", MEMINFO }
local swap_pct = 100
if ok_m then
    local total = tonumber(mem:match("SwapTotal:%s+(%d+)") or "0")
    local free = tonumber(mem:match("SwapFree:%s+(%d+)") or "0")
    if total > 0 then
        swap_pct = math.floor(free * 100 / total)
        if swap_pct < SWAP_PCT then
            refuse("swap-low", string.format("%d%% of swap free, floor %d%%; remedy: stop runaway processes (stale browser windows, leftover gates) before gating", swap_pct, SWAP_PCT))
        end
    end
end

verdict.emit(string.format("ok:host-door:disk=%.0fG tmp=%.1fG swap-free=%d%%", disk, tmpfree, swap_pct), 0)
