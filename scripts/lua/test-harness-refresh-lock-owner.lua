-- @env PATH
-- @trace order:1971-rikj, order:284, spec:default-image
--
-- test-harness-refresh-lock-owner.lua — a harness-refresh lock left on the
-- persistent tool cache by a stopped forge is reclaimed at once; a live
-- holder in the same container is respected, and says so (1971-rikj).
--
-- MEASURED on yoga 2026-11-02: a forge stopped mid-refresh left
-- npm-update.lock behind (no EXIT trap ran) and the next three launches
-- returned from ensure_forge_harnesses with no lifecycle line at all — the
-- harnesses were not refreshed until the lock aged past 60 minutes.
--
-- The arms EXECUTE the real ensure_forge_harnesses, cut out of
-- images/default/lib-common.sh by name, with no npm on PATH. The NEXT
-- CHECKPOINT after taking the lock is its "npm not available" line, so an
-- arm that took the lock is told apart from one that returned early.
--   1 FOREIGN  a lock whose holder is another container: reclaimed, refresh
--              runs (today: silent skip)
--   2 DEADPID  a holder in this container whose pid is gone: reclaimed
--   3 LEGACY   a lock with no holder file, 2 minutes old: reclaimed
--   4 LIVE     a holder in this container whose pid is alive: respected,
--              with one "skipped: refresh in progress" line, never silent
--
-- Usage: tillandsias-plan script run scripts/lua/test-harness-refresh-lock-owner.lua
-- Verdict: ok:harness-refresh-lock-owner:<n> arms | violation:harness-refresh-lock-owner:<n>-failed

local NAME = "harness-refresh-lock-owner"
local LIB = "images/default/lib-common.sh"
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function readf(p) return fs.exists(p) and (fs.read(p) or "") or "" end

local lines = text.lines(fs.read(LIB) or "")
local buf, inside = {}, false
for _, l in ipairs(lines) do
    if not inside and l:find("^ensure_forge_harnesses%(%)%s*{") then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
local fn = table.concat(buf, "\n") .. "\n"

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/lock-owner-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
local LOCK_REL = REL .. "/home/.cache/tillandsias-project/npm-update.lock"
local LOCK = root .. "/" .. LOCK_REL
fs.mkdir(REL .. "/home/.cache/tillandsias-project")
fs.write(REL .. "/fn.sh", fn)
-- npm is absent from the system dirs on PATH (premise checked below)

local function launch(live)
    proc.run{ argv = { "rm", "-f", ABS .. "/lifecycle" } }
    fs.write(REL .. "/run.sh", table.concat({
        'trace_lifecycle() { echo "$1 | $2" >> "' .. ABS .. '/lifecycle"; }',
        ". " .. ABS .. "/fn.sh",
        live and ('printf "this-forge %s\\n" "$$" > "' .. LOCK .. '/holder"') or ":",
        "( ensure_forge_harnesses )",
    }, "\n") .. "\n")
    local r = proc.run{ argv = { "/bin/bash", ABS .. "/run.sh" }, timeout_ms = 30000,
        env = { PATH = "/usr/bin:/bin", HOME = ABS .. "/home", HOSTNAME = "this-forge" } }
    return r, readf(REL .. "/lifecycle")
end
local function plant(holder, minutes_old)
    proc.run{ argv = { "rm", "-rf", LOCK } }
    fs.mkdir(LOCK_REL)
    if holder then fs.write(LOCK_REL .. "/holder", holder .. "\n") end
    if minutes_old then
        -- touch -t is accepted by GNU and BSD; -d "N minutes ago" is GNU-only
        -- (macbookair darwin regime run, 2026-11-03)
        proc.run{ argv = { "touch", "-t", os.date("%Y%m%d%H%M.%S", os.time() - minutes_old * 60), LOCK } }
    end
end
local function took(life) return life:find("npm not available", 1, true) ~= nil end

arm("0 premise: ensure_forge_harnesses was cut and takes npm-update.lock",
    fn:find("^ensure_forge_harnesses%(%)") ~= nil and fn:find("npm-update.lock", 1, true) ~= nil, #fn)

plant("other-container 4242", 2)
local r, life = launch()
arm("1 FOREIGN: another container's lock is reclaimed and the refresh runs",
    r.code == 0 and life:find("reclaimed npm-update lock", 1, true) ~= nil and took(life),
    "rc=" .. tostring(r.code) .. " life=" .. life:sub(1, 200))

plant("this-forge 999999", nil)
r, life = launch()
arm("2 DEADPID: a gone holder in this container is reclaimed",
    r.code == 0 and life:find("reclaimed npm-update lock", 1, true) ~= nil and took(life),
    "rc=" .. tostring(r.code) .. " life=" .. life:sub(1, 200))

plant(nil, 2)
r, life = launch()
arm("3 LEGACY: a holder-less lock two minutes old is reclaimed",
    r.code == 0 and life:find("reclaimed npm-update lock", 1, true) ~= nil and took(life),
    "rc=" .. tostring(r.code) .. " life=" .. life:sub(1, 200))

-- a live holder: run.sh records its OWN pid ($$), alive while the subshell asks
plant(nil, nil)
r, life = launch(true)
arm("4 LIVE: a live holder is respected, with one skip line, not silence",
    r.code == 0 and not took(life) and life:find("skipped: refresh in progress", 1, true) ~= nil
        and fs.exists(LOCK_REL .. "/holder"),
    "rc=" .. tostring(r.code) .. " life=" .. life:sub(1, 200))

proc.run{ argv = { "rm", "-rf", ABS } }
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
