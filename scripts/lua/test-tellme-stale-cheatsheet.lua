-- @env PATH HOME
-- @trace order:2080-kkki
--
-- test-tellme-stale-cheatsheet.lua — `tellme about <sheet>` marks a cheatsheet stale when its
-- last_verified is older than the ruled age, and marks nothing while no age is ruled.
--
-- WHY (2080-kkki). 185 of 256 sheets were last verified in April or May, and a stale one
-- (wsl-bash.md) misled a blind designer; an agent reading a sheet had no way to see its age.
-- RULING (coordinator, 2026-11-27): the age is the operator's; until then it is ONE config value
-- (CHEATSHEET_STALE_DAYS in images/default/cli/tellme, or TILLANDSIAS_CHEATSHEET_STALE_DAYS),
-- defaulting to unset, so the ruling is a one-line change.
--   1 DEFAULT   the shipped value is unset (nil)
--   (each arm runs `tellme about <sheet> --full`, the path that prints one sheet)
--   2 UNSET     with no age, an old sheet prints with no STALE banner (today's behaviour)
--   3 OLD       with 90 days, a sheet last verified 2020-01-01 prints a STALE banner naming its date
--   4 FRESH     with 90 days, a sheet verified today prints no banner
--   5 NO DATE   with 90 days, a sheet recording no last_verified reads stale
-- tellme is loaded in a sandboxed Lua world whose io.popen runs a real shell (the shape of
-- test-tellme-routes-to-expert-serve.lua), so no image is built.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tellme-stale-cheatsheet.lua
-- Verdict: ok:tellme-stale-cheatsheet:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("tellme-stale-cheatsheet")
local SH = fixture.posix_shell()
local ROOT = fixture.repo_root()
local SUBJECT = "images/default/cli/tellme"
local src = fs.read(SUBJECT) or ""
T:arm("1 DEFAULT the shipped stale age is unset", src:find("\nlocal CHEATSHEET_STALE_DAYS = nil\n", 1, true) ~= nil)

local W = T:scratch()
fs.mkdir(W.rel .. "/cheatsheets/runtime")
fs.write(W.rel .. "/cheatsheets/INDEX.md", "# Cheatsheet index\n\n## runtime\n- runtime/oldsheet.md — old\n")
local today = text.trim(proc.run{ argv = { "date", "-u", "+%Y-%m-%d" }, timeout_ms = 5000 }.stdout or "")
local function sheet(name, lv)
    fs.write(W.rel .. "/cheatsheets/runtime/" .. name .. ".md",
        "---\ntitle: " .. name .. "\n" .. (lv and ('last_verified: "' .. lv .. '"\n') or "") .. "---\n\n# " .. name .. "\n\nbody of " .. name .. "\n")
end
sheet("oldsheet", "2020-01-01"); sheet("freshsheet", today); sheet("nodatesheet", nil)

local function tellme(args, days)
    local so, stop = {}, {}
    local function sink(t) return { write = function(self, ...) for _, v in ipairs({ ... }) do t[#t + 1] = v end return self end,
        flush = function(self) return self end } end
    local e = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = W.abs, TILLANDSIAS_CHEATSHEETS = W.abs .. "/cheatsheets",
        TILLANDSIAS_CHEATSHEET_STALE_DAYS = days, TELLME_EXPERT_URL = "http://127.0.0.1:9" }
    local world = { string = string, table = table, math = math, ipairs = ipairs, pairs = pairs, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        arg = { [0] = ROOT .. "/" .. SUBJECT, table.unpack(args) },
        io = { stdout = sink(so), stderr = sink(so), popen = function(c)
            local r = proc.run({ argv = { SH, "-s" }, stdin = c .. "\n", env = e, timeout_ms = 60000 })
            local s = r.stdout or ""
            return { read = function() local x = s; s = ""; return x end,
                close = function() return r.code == 0 or nil, "exit", r.code end }
        end },
        os = { getenv = function(n) return e[n] end, exit = function(c) stop.code = c; error(stop) end } }
    local f, why = load((src:gsub("^#![^\n]*", "")), "=tellme", "t", world)
    if not f then return "load: " .. tostring(why) end
    local ok, got = pcall(f)
    if not ok and got ~= stop then so[#so + 1] = "error: " .. tostring(got) end
    return table.concat(so)
end

local o = tellme({ "about", "oldsheet", "--full" }, nil)
T:arm("2 UNSET an old sheet prints with no STALE banner", text.contains(o, "body of oldsheet") and not text.contains(o, "[STALE"), o:sub(1, 300))
o = tellme({ "about", "oldsheet", "--full" }, "90")
T:arm("3 OLD a sheet past the age prints a STALE banner naming its date", text.contains(o, "[STALE: last verified 2020-01-01") and text.contains(o, "body of oldsheet"), o:sub(1, 300))
o = tellme({ "about", "freshsheet", "--full" }, "90")
T:arm("4 FRESH a sheet within the age prints no banner", text.contains(o, "body of freshsheet") and not text.contains(o, "[STALE"), o:sub(1, 300))
o = tellme({ "about", "nodatesheet", "--full" }, "90")
T:arm("5 NO DATE a sheet recording no last_verified reads stale", text.contains(o, "[STALE: this cheatsheet records no last_verified date"), o:sub(1, 300))
T:finish()
