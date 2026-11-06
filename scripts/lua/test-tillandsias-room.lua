-- @trace order:2006-srcr
-- @env PATH
--
-- test-tillandsias-room.lua — the forge's checkout-room check
-- (images/default/cli/tillandsias-room) against a REAL 8 MiB tmpfs mounted in a
-- rootless user+mount namespace (unshare -rm), standing in for /home/forge/src
-- of a project with a large build dir:
--   1 ROOMY   at low use: exit 0, use_pct reported, no warning
--   2 FULL    at >= 85%: warn:forge-src-room names the path, the free MB, and
--             the remedy "BUILD OUTPUTS, NOT SECRETS"; exit 1
--   3 BIGGEST the largest directory (the build dir) is named first
--   4 RECORD  --record writes the high-water MB into the project cache file,
--             and a later, smaller use never lowers it
--   5 QUIET   --quiet prints nothing when there is room
-- Red before 2006-srcr: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-room.lua

local TOOL = "images/default/cli/tillandsias-room"
if not fs.exists(TOOL) then
    verdict.emit("violation:tillandsias-room:no-subject", 1, TOOL .. " does not exist")
end
local PATHV = env.get("PATH") or "/usr/bin:/bin"
local c0 = proc.run({ argv = { "unshare", "-rm", "true" }, env = { PATH = PATHV }, timeout_ms = 30000 })
if c0.status ~= "exited" or c0.code ~= 0 then
    verdict.could_not_run("tillandsias-room", "unshare -rm (a rootless mount namespace) is not available here")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/tr" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
fs.mkdir(REL .. "/src")
fs.mkdir(REL .. "/cache")

-- One namespace per scenario: mount an 8 MiB tmpfs, fill it, run the tool.
local function scenario(fill_mb, args)
    local script = table.concat({
        "set -e",
        "mount -t tmpfs -o size=8m tmpfs '" .. DIR .. "/src'",
        "mkdir -p '" .. DIR .. "/src/game/build' '" .. DIR .. "/src/game/assets'",
        "head -c " .. tostring(fill_mb * 1024 * 1024) .. " /dev/zero > '" .. DIR .. "/src/game/build/out.bin'",
        "head -c 262144 /dev/zero > '" .. DIR .. "/src/game/assets/a.bin'",
        "exec python3 '" .. ROOT .. "/" .. TOOL .. "' " .. table.concat(args, " "),
    }, "\n")
    local r = proc.run({ argv = { "unshare", "-rm", "sh", "-c", script },
        env = { PATH = PATHV, TILLANDSIAS_ROOM_PATH = DIR .. "/src", TILLANDSIAS_ROOM_CACHE = DIR .. "/cache" },
        timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or ""
end
local function has(s, n) return (s or ""):find(n, 1, true) ~= nil end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

local c, o, e = scenario(1, {})
arm("1 ROOMY low use exits 0 with no warning", c == 0 and has(o, '"use_pct"') and not has(o, "warn:"), c .. " " .. o .. e)

c, o, e = scenario(7, { "--record" })
arm("2 FULL >= 85% warns by name with the remedy", c == 1 and has(o, "warn:forge-src-room:")
    and has(o, DIR .. "/src") and has(o, "MB free") and has(o, "BUILD OUTPUTS, NOT SECRETS"), c .. " " .. o .. e)
arm("3 BIGGEST the directory holding the build is named first",
    has(o, '"largest": [{"path": "' .. DIR .. '/src/game", "mb": 7}'), o)
local rec1 = tonumber(text.trim(fs.read(REL .. "/cache/.tillandsias/src-highwater-mb") or "0"))

c, o, e = scenario(1, { "--record", "--quiet" })
local rec2 = tonumber(text.trim(fs.read(REL .. "/cache/.tillandsias/src-highwater-mb") or "0"))
arm("4 RECORD the high-water mark is written and never lowered", rec1 and rec1 >= 7 and rec2 == rec1,
    tostring(rec1) .. " -> " .. tostring(rec2))
arm("5 QUIET prints nothing when there is room", c == 0 and text.trim(o) == "", c .. " [" .. o .. "]")

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-room:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-room", passed .. " arms")
