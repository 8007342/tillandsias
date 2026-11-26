-- @env PATH
-- @trace order:1384-bp6t, order:1254-fdsu, order:2300-6m9m
--
-- test-lua-determinism.lua — one Lua script, one byte stream, on any host. Ported from the
-- .sh of the same name (2300-6m9m). PRE-FIX (yoga 2026-09-26): three processes encoding one
-- 12-key table printed three different 206-byte streams, because Lua 5.4 seeds string
-- hashing per process; and os.setlocale("") under a comma-radix locale flipped %.2f.
--
--   1 SAME      three processes print the same NON-EMPTY bytes (empty would compare equal)
--   2 ORDER     keys in byte order, in json.encode and in pairs
--   3 LIST      fs.list is one byte stream for a given tree
--   4 OBSERVING os.setlocale nil, next withheld naming table.is_empty, table.keys sorted
--   5 CACHEABLE the same, with os itself nil
--   6 LOCALE    under an installed comma-radix locale, a script that TRIES os.setlocale still
--               formats 3.50 and tonumber("3,5") is nil (named skip with no such locale)
--
-- Usage: tillandsias-plan script run scripts/lua/test-lua-determinism.lua
-- Verdict: ok:lua-determinism:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("lua-determinism")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
local function lua(args, e)
    local a = { PLAN, "lua" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    local r = proc.run{ argv = a, cwd = ROOT, env = e, timeout_ms = 60000 }
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local function thrice(args)
    local _, a = lua(args); local _, b = lua(args); local _, c = lua(args)
    return a, a == b and b == c, a .. " | " .. b .. " | " .. c
end

local o, same, all = thrice{ "--class", "cacheable", "scripts/fixtures/determinism.lua" }
T:arm("1 SAME three processes print the same bytes", o:match('^{"') ~= nil and same, all:sub(1, 300))
local KEYS = '{"alpha":1,"beta":2,"delta":4,"eps":5,"eta":7,"gamma":3,"iota":9,"kappa":10,"lambda":11,"mu":12,"theta":8,"zeta":6}'
T:arm("2 ORDER keys in byte order, in json.encode and in pairs", o:sub(1, #KEYS) == KEYS and text.contains(o, "alpha=1,beta=2,delta=4,"), o:sub(1, 200))
local l, lsame, lall = thrice{ "-e", 'return table.concat(fs.list("scripts/fixtures"), ",")' }
T:arm("3 LIST fs.list is one byte stream", text.contains(l, "determinism.lua") and lsame, lall:sub(1, 300))

local function probe(first)
    return 'local ok, e = pcall(function() return next end); '
        .. 'local nx = (not ok and tostring(e):find("table.is_empty", 1, true)) and "next-named" or ("next:" .. tostring(ok) .. ":" .. tostring(e)); '
        .. "return tostring(" .. first .. '), nx, table.concat(table.keys({b=1,a=2,[3]=0,[1]=0}), ","), tostring(table.is_empty({})) .. tostring(table.is_empty({a=1}))'
end
local WANT = "nil next-named 1,3,a,b truefalse"
local _, v = lua{ "-e", probe("os.setlocale") }
T:arm("4 OBSERVING os.setlocale nil, next withheld by name, keys sorted", v:gsub("%s+", " ") == WANT, v)
_, v = lua{ "--class", "cacheable", "-e", probe("os") }
T:arm("5 CACHEABLE os nil, next withheld by name, keys sorted", v:gsub("%s+", " ") == WANT, v)

local loc
local ok, r = pcall(proc.run, { argv = { "locale", "-a" }, timeout_ms = 30000 })
local have = "\n" .. (ok and r.stdout or "") .. "\n"
for _, c in ipairs{ "fr_FR.UTF-8", "fr_FR.utf8", "br_FR.UTF-8", "br_FR.utf8", "de_DE.UTF-8", "de_DE.utf8" } do
    if not loc and have:find("\n" .. c .. "\n", 1, true) then loc = c end
end
if not loc then out.line("skip: 6 LOCALE no comma-radix locale installed (fr_FR/br_FR/de_DE)")
else
    -- The arm ATTEMPTS the attack: without os.setlocale a bare format reads 3.50 pre-fix too.
    _, v = lua({ "-e", 'local f = type(os) == "table" and os.setlocale; if f then f("") end; return string.format("%.2f", 3.5), tostring(tonumber("3,5"))' },
        { PATH = env.get("PATH"), LC_ALL = loc })
    T:arm("6 LOCALE under " .. loc .. " %.2f is 3.50 and 3,5 is not a number", v:gsub("%s+", " ") == "3.50 nil", v)
end
T:finish()
