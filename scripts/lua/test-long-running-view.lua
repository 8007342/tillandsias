-- @env PATH HOME
-- @trace spec:meta-orchestration, order:251, order:943-26rx, order:2384-5fj5
--
-- test-long-running-view.lua — scripts/lua/check-long-running-view.lua on fixture indexes and views: a live
-- multi_cycle packet missing from the view and a row naming a terminal one are both refused; an agreeing
-- pair passes, and a packet that is not multi_cycle is not demanded. The fragment overlay reads a packet the
-- fold has closed as terminal while the base says ready, and keeps a live one live. Each main assertion has
-- a mutant. These were the hermetic steps of litmus:long-running-view-agreement while the decider was shell.
--
-- Usage: tillandsias-plan script run scripts/lua/test-long-running-view.lua
-- Verdict: ok:long-running-view-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("long-running-view-fixture")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local SUBJECT = "scripts/lua/check-long-running-view.lua"
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local W = T:scratch()

local function pkt(id, order, status, mc)
    return "    - packet_id: " .. id .. "\n      order: " .. order .. "\n      status: " .. status .. "\n" .. (mc and "      multi_cycle: true\n" or "")
end
local seq = 0
-- The decider (or `body`) on an index of packets and a view of orders.
local function judge(packets, orders, body)
    seq = seq + 1
    local idx, vw = W.rel .. "/idx" .. seq .. ".yaml", W.rel .. "/view" .. seq .. ".md"
    fs.write(idx, "plan_index:\n  packets:\n" .. table.concat(packets))
    local rows = { "| Order | Packet |", "|---:|---|" }
    for _, o in ipairs(orders) do rows[#rows + 1] = "| " .. o .. " | `x` |" end
    fs.write(vw, table.concat(rows, "\n") .. "\nprose naming 777 is not a listing\n")
    local script = SUBJECT
    if body then local mpath = W.rel .. "/mutant" .. seq .. ".lua"; fs.write(mpath, body); script = mpath end
    local r = T:run{ PLAN, "script", "run", script, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_LONG_RUNNING_INDEX = W.abs .. "/idx" .. seq .. ".yaml",
            TILLANDSIAS_LONG_RUNNING_VIEW = W.abs .. "/view" .. seq .. ".md" } }
    local line = text.trim((r.stdout or ""):gsub("\r", ""))
    return { code = r.code, line = line, got = "rc=" .. tostring(r.code) .. " " .. line .. " " .. (r.stderr or ""):sub(1, 300) }
end
local function is(name, x, code, line) return T:arm(name, x.code == code and x.line == line, x.got) end

local A, B = pkt("alpha", "900", "ready", true), pkt("beta", "901", "ready", true)
local GONE, PLAIN = pkt("gamma", "902", "obsoleted", true), pkt("plain", "903", "ready")
local MISSING = { { A, B }, { "900" } }
local STALE = { { A, GONE }, { "900", "902" } }
is("1 a live multi_cycle packet missing from the view is refused", judge(MISSING[1], MISSING[2]), 1, "violation:long-running-view:missing=1:stale=0")
is("2 a row naming a terminal packet is refused", judge(STALE[1], STALE[2]), 1, "violation:long-running-view:missing=0:stale=1")
is("3 CONTROL an agreeing pair passes, the terminal packet excluded", judge({ A, GONE }, { "900" }), 0, "ok:long-running-view:1 live packets listed")
is("4 CONTROL a packet that is not multi_cycle is not demanded", judge({ A, PLAIN }, { "900" }), 0, "ok:long-running-view:1 live packets listed")
is("5 an index with no multi_cycle packet is the instrument failing, not ok:0", judge({ PLAIN }, {}), 2, "blocked:no-multi-cycle-packets-parsed")
-- 831-ezea is completed in the fold (terminal stays terminal; if it is ever resurrected, change the subject,
-- not the assertion). 245 is a live multi_cycle order.
local CLOSED = { { pkt("subject", "831-ezea", "ready", true) }, { "831-ezea" } }
local OPEN = { { pkt("subject", "245", "ready", true) }, { "245" } }
is("6 a packet the fold has closed reads terminal while the base says ready", judge(CLOSED[1], CLOSED[2]), 1, "violation:long-running-view:missing=0:stale=1")
is("6 CONTROL the overlay only refines: a live packet stays live", judge(OPEN[1], OPEN[2]), 0, "ok:long-running-view:1 live packets listed")
local live = T:run{ PLAN, "script", "run", SUBJECT }
T:arm("7 on this tree the view agrees, in the pinned grammar", live.code == 0
    and text.trim(live.stdout or ""):find("^ok:long%-running%-view:%d+ live packets listed$") ~= nil, live.stdout)

-- MUTATION
local function mutant(from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return src:sub(1, a - 1) .. to .. src:sub(b + 1)
end
local x = judge(MISSING[1], MISSING[2], mutant("local missing, stale = minus(live, listed), minus(listed, live)", "local missing, stale = {}, minus(listed, live)"))
T:arm("8 MUTATION a check blind to omissions fails arm 1", x.code == 0, x.got)
x = judge(STALE[1], STALE[2], mutant("local missing, stale = minus(live, listed), minus(listed, live)", "local missing, stale = minus(live, listed), {}"))
T:arm("8 MUTATION a check blind to stale rows fails arm 2", x.code == 0, x.got)
x = judge(CLOSED[1], CLOSED[2], mutant("local s = fold and fold[o]", "local s = base[o] and \"ready\""))
T:arm("8 MUTATION no overlay fails arm 6", x.code == 0, x.got)
x = judge(OPEN[1], OPEN[2], mutant("if not TERMINAL[s] then live[o] = true end", "if false then live[o] = true end"))
T:arm("8 MUTATION an overlay that widens to terminal fails arm 6's control", x.code == 1, x.got)
x = judge({ A, PLAIN }, { "900" }, mutant("elseif l:find(\"^      multi_cycle: true\") then mc = true end", "else mc = true end"))
T:arm("8 MUTATION a check that demands every packet fails arm 4", x.code == 1, x.got)

T:finish()
