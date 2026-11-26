-- @trace order:895-j8ag, order:2375-ch7i
--
-- test-daily-maintenance-day-boundary.lua — the daily-maintenance gate's day boundary is
-- UTC. It compared the LOCAL date with a marker recording both, so hosts off UTC read
-- current after the UTC day had rolled (measured on three UTC-7 hosts). `date -u` ignores
-- TZ and `date` does not, so a verdict that moves when only TZ moves reads local time; both
-- signs of offset are exercised. Ported from the .sh (2375-ch7i).
--
-- Verdict: ok:daily-maintenance-day-boundary:all | fail:daily-maintenance-day-boundary: <arms>

local fixture = require "common.fixture"
local T = fixture.new("daily-maintenance-day-boundary")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local GUARD = "scripts/check-daily-maintenance.sh"
local function marker(name, date, utc)
    fs.write(W.rel .. "/" .. name, "date=" .. date .. " utc=" .. utc .. " host=fixture steps=probe:ok\n")
    return W.abs .. "/" .. name
end
local function check(m, tz, today, script)
    return text.trim(T:run{ SH, script or GUARD, "check", cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
        env = { TZ = tz, TILLANDSIAS_DAILY_MAINTENANCE_MARKER = m, TILLANDSIAS_DAILY_MAINTENANCE_TODAY = today } }.stdout or "")
end
local M = marker("marker", "2026-08-25", "2026-08-25T20:14:30Z")
local same, nxt = check(M, "UTC", "2026-08-25"), check(M, "UTC", "2026-08-26")
T:arm("1 current on the marker's own UTC day", same == "ok:daily-maintenance-current:2026-08-25", same)
T:arm("1 stale one UTC day later, naming the stale day", nxt == "due:stale:2026-08-25", nxt)
local current = {}
for _, d in ipairs{ "2026-08-23", "2026-08-24", "2026-08-25", "2026-08-26", "2026-08-27" } do
    if check(M, "UTC", d):find("^ok:daily%-maintenance%-current:") then current[#current + 1] = d end
end
T:arm("1 exactly one day in five reads current, the marker's", table.concat(current, " ") == "2026-08-25", table.concat(current, " "))
local utc, neg, pos = check(M, "UTC"), check(M, "America/Los_Angeles"), check(M, "Asia/Tokyo")
T:arm("2 TZ does not move the verdict", utc ~= "" and utc == neg and utc == pos, utc .. " / " .. neg .. " / " .. pos)
local late, off = marker("late", "2026-08-25", "2026-08-25T23:50:00Z"), {}
for _, tz in ipairs{ "UTC", "America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati" } do
    local v = check(late, tz, "2026-08-26")
    if v ~= "due:stale:2026-08-25" then off[#off + 1] = tz .. "=" .. v end
end
T:arm("2 the previous UTC day's marker is stale in every zone", #off == 0, table.concat(off, " "))
local D = "%d%d%d%d%-%d%d%-%d%d"
local esc = {}
for _, v in ipairs{ same, nxt, neg, pos } do
    if not (v:find("^ok:daily%-maintenance%-current:" .. D .. "$") or v:find("^ok:daily%-maintenance%-stamped:" .. D .. "$") or v == "skip:forge-exempt"
        or v == "due:no-marker" or v == "due:unreadable-marker" or v:find("^due:stale:" .. D .. "$")) then esc[#esc + 1] = v end
end
T:arm("3 every verdict matches the pinned grammar", #esc == 0, table.concat(esc, " "))
local miss = check(W.abs .. "/absent-marker", "UTC", "2026-08-26")
T:arm("3 an absent marker is due:no-marker", miss == "due:no-marker", miss)
fs.write(W.rel .. "/corrupt", "garbage\n")
local bad = check(W.abs .. "/corrupt", "UTC", "2026-08-26")
T:arm("3 a corrupt marker is due:unreadable-marker", bad == "due:unreadable-marker", bad)
T:run{ SH, GUARD, "stamp", "--host", "fixture", "--steps", "probe:ok", cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
    env = { TILLANDSIAS_DAILY_MAINTENANCE_MARKER = W.abs .. "/stamped" } }
local st = fs.exists(W.rel .. "/stamped") and fs.read(W.rel .. "/stamped") or ""
local sd, su = st:match("^date=(" .. D .. ") utc=(" .. D .. ")T[%d:]+Z ")
T:arm("4 the stamp records both date= and utc=", sd, st)
T:arm("4 and they agree on the UTC day", sd and sd == su, tostring(sd) .. " / " .. tostring(su))
-- MUTATION: the pre-fix guard, its local date pinned at 2026-08-25T23:50:00Z (BSD's
-- `date -r <epoch>` first; under GNU that reads a file and fails over to -d), must disagree.
local src = fs.read(GUARD)
local line = 'TODAY="${TILLANDSIAS_DAILY_MAINTENANCE_TODAY:-$(date -u +%Y-%m-%d'
local at = src:find(line, 1, true)
if not at then T:arm("5 the pre-fix guard can be reconstructed", false, "the TODAY= line moved")
else
    local e = "1787701800"
    fs.write(W.rel .. "/pre.sh", src:sub(1, at - 1) .. 'TODAY="${TILLANDSIAS_DAILY_MAINTENANCE_TODAY:-$(date -r ' .. e .. " +%Y-%m-%d 2>/dev/null || date -d @" .. e
        .. " +%Y-%m-%d" .. src:sub(at + #line)) -- gnu-date: ok (BSD -r first; -d is the GNU fallback)
    local a = check(late, "America/Los_Angeles", nil, W.abs .. "/pre.sh")
    local b = check(late, "Asia/Tokyo", nil, W.abs .. "/pre.sh")
    T:arm("5 MUTATION the pre-fix guard disagrees across zones", a ~= b and a ~= "" and b ~= "", a .. " / " .. b)
end
T:finish({ ok = function() return "ok:daily-maintenance-day-boundary:all" end,
    fail = function(_, f) return "fail:daily-maintenance-day-boundary: " .. table.concat(f, " | ") end })
