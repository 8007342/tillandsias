-- @env PATH HOME
-- @trace order:896-f8ti, order:699-usxc, order:1564-lk9f, order:2367-wtse
--
-- test-append-event-archived-refusal.lua — append-event refuses a reference to an ARCHIVED packet,
-- by that name, and one that matches nothing, by another; a live packet still takes events. Ported
-- from the .sh of the same name (2367-wtse). Every write goes to a scratch copy of this ledger
-- under target/, so a kill at any moment leaves this checkout clean (1564-lk9f).
--
--   1 archived: refused, saying archived     2 nonexistent: refused, not saying archived
--   3 neither wrote a fragment               4 a live ready packet accepts an event (699-usxc)
--
-- Usage: tillandsias-plan script run scripts/lua/test-append-event-archived-refusal.lua
-- Verdict: ok:append-event-archived-refusal:<n> arms | violation:... | skip:append-event-archived-refusal:...

local fixture = require "common.fixture"
local T = fixture.new("append-event-archived-refusal")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local archived
for _, f in ipairs(fs.list("plan/archive")) do
    local n = f:match("([^/]+%.yaml)$")
    archived = archived or n and ("\n" .. fs.read("plan/archive/" .. n)):match('\n      order: "?(%d+%-[a-z0-9]+)')
end
if not archived then T:skip("no-archived-order-found") end
local d = T:scratch()
fs.mkdir(d.rel .. "/plan")
T:must{ "cp", "-R", ROOT .. "/plan/index.yaml", ROOT .. "/plan/index.d", ROOT .. "/plan/archive", d.abs .. "/plan/" }
local AGENT = "linux-fixture-claude-20260101t000000z"
local function append(order, summary)
    local r = proc.run{ argv = { PLAN, "--index", d.abs .. "/plan/index.yaml", "append-event", order, "note", "append-event-archived-refusal fixture probe: " .. summary, "--agent", AGENT, "--host", "fixture" },
        cwd = ROOT, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    -- This fixture's own paths spell the word the arms look for.
    o = o:gsub("%S*append%-event%-archived%-refusal%S*", "<path>")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400)
end
local function fragments()
    local n = 0
    for _, f in ipairs(fs.list(d.rel .. "/plan/index.d")) do
        if f:match("%.yaml$") then n = n + 1 end
    end
    return n
end
local before = fragments()
local rc, o, why = append(archived, "must refuse")
T:arm("1 an archived reference is refused, and the refusal says archived", rc ~= 0 and text.contains(o:lower(), "archived"), why)
rc, o, why = append("999999-zzzzzz", "must refuse")
T:arm("2 one matching nothing is refused, and does not say archived", rc ~= 0 and not text.contains(o:lower(), "archived"), why)
T:arm("3 neither refusal wrote a fragment", before > 0 and fragments() == before, before .. " -> " .. fragments())
local index, live = "\n" .. fs.read("plan/index.yaml"), nil
for _, f in ipairs(fs.list("plan/index.d")) do
    local n = not live and f:match("([^/]+%.yaml)$")
    if n then
        local s = "\n" .. fs.read("plan/index.d/" .. n)
        local order = s:match('\n    order: "?(%d+%-[a-z0-9]+)')
        if order and s:match("\n    status: ([a-z_]+)") == "ready" and not text.contains(index, '      order: "' .. order .. '"\n') and not text.contains(index, "      order: " .. order .. "\n") then live = order end
    end
end
if live then
    rc, o, why = append(live, "live packets must still accept events (699-usxc preserved)")
    T:arm("4 a live packet still accepts events", rc == 0, live .. " " .. why)
    T:arm("4b and the event is one fragment in the scratch ledger", fragments() == before + 1, before .. " -> " .. fragments())
else
    out.line("skip: 4 no live ready packet to test against")
end
T:finish()
