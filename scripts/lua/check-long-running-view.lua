-- @env PATH HOME TILLANDSIAS_LONG_RUNNING_VIEW TILLANDSIAS_LONG_RUNNING_INDEX TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace spec:meta-orchestration, order:251, order:943-26rx, order:964-tzmp, order:2384-5fj5
--
-- check-long-running-view.lua — order 251 criterion LM-04: plan/long-running.md is declared a FILTERED VIEW of
-- the active `multi_cycle: true` packets (methodology/distributed-work.yaml -> long_running_packets.sub_queue_view).
-- Measured on yoga 2026-08-25: 11 rows, four naming obsoleted packets, twenty live ones absent. A sub-queue
-- that is 23% accurate is a decoy, so the invariant is machine-checked.
--
-- It compares SETS, not rendering: which orders appear is derivable and is what rotted; the phase,
-- blocked-on and verification columns are editorial.
--
-- THE FRAGMENT OVERLAY (943-26rx). The base is read for (order, status, multi_cycle); then the plan binary,
-- the folding reader, may move an order from live to terminal, never the other way. set-field writes a
-- fragment and the base keeps the old status until the next fold, so without it a closed packet would be
-- demanded in the view. One `query --json` answers the live fold; an order absent from it may be ARCHIVED,
-- and only those pay a `status <order>` (964-tzmp). No usable binary degrades to the base-only answer.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/check-long-running-view.lua
--   TILLANDSIAS_LONG_RUNNING_VIEW / _INDEX name another view and index (a fixture's).
-- Verdict (one line on stdout):
--   ok:long-running-view:<n> live packets listed          exit 0
--   violation:long-running-view:missing=<n>:stale=<n>     exit 1
--   blocked:<reason>                                      exit 2

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local VIEW = env.get("TILLANDSIAS_LONG_RUNNING_VIEW") or "plan/long-running.md"
local INDEX = env.get("TILLANDSIAS_LONG_RUNNING_INDEX") or "plan/index.yaml"
local TERMINAL = { done = true, obsoleted = true, superseded = true, completed = true, failed = true, cancelled = true }

-- Through the shell: a fixture's index and view live in a temp dir the fs door cannot reach.
local function slurp(p)
    local r = proc.run{ argv = { SH, "-s", "--", p }, stdin = '[ -r "$1" ] && cat -- "$1"\n', timeout_ms = 60000 }
    if r.code ~= 0 then return nil end
    return (r.stdout or ""):gsub("\r\n", "\n")
end
local index = slurp(INDEX)
if not index then verdict.emit("blocked:index-unreadable:" .. INDEX, 2) end
local view = slurp(VIEW)
if not view then verdict.emit("blocked:view-unreadable:" .. VIEW, 2) end

-- One pass over the packet list, (order, status, multi_cycle) per packet, emitted at the boundary. Not a
-- window of lines: a packet's field order varies, and this file is hand-edited by many hosts.
local function unquote(s) return (s:gsub("[\"']", "")) end
local base, ord, status, mc = {}, nil, nil, false
local function flush()
    if mc and ord and ord ~= "" and not TERMINAL[status or ""] then base[ord] = true end
    ord, status, mc = nil, nil, false
end
for l in (index .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("^    %- packet_id: ") then flush()
    elseif not ord and l:find("^      order: ") then ord = unquote(l:match("^      order: (%S*)") or "")
    elseif not status and l:find("^      status: ") then status = unquote(l:match("^      status: (%S*)") or "")
    elseif l:find("^      multi_cycle: true") then mc = true end
end
flush()
local any = false
for _ in pairs(base) do any = true end
-- The emptiness guard asks the BASE PARSE: a tree whose multi_cycle packets were all closed is a true ok:0,
-- and a parser that produced nothing is the instrument failing.
if not any then verdict.emit("blocked:no-multi-cycle-packets-parsed", 2) end

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = fixture.plan_binary() end
local live = {}
if PLAN == "" then
    for o in pairs(base) do live[o] = true end
else
    local fold
    local q = proc.run{ argv = { PLAN, "query", "--json", "--limit", "0" }, timeout_ms = 120000 }
    if q.code == 0 then
        local ok_, rows = pcall(json.parse, q.stdout or "")
        if ok_ and type(rows) == "table" then
            fold = {}
            for _, row in ipairs(rows) do
                if type(row) == "table" then
                    local key = row.order ~= json.null and row.order or row.packet_id
                    if key ~= nil and key ~= json.null and tostring(key) ~= "" then
                        fold[tostring(key)] = row.status ~= json.null and tostring(row.status or "") or ""
                    end
                end
            end
        end
    end
    for o in pairs(base) do
        local s = fold and fold[o]
        if s == nil then -- absent from the live fold, or no fold at all: ask the archive-aware reader
            local st = proc.run{ argv = { PLAN, "status", o }, timeout_ms = 60000 }
            s = ((st.stdout or ""):match("^%S+%s+(%S+)")) or ""
        end
        if not TERMINAL[s] then live[o] = true end
    end
end

-- Orders the view claims: the leading cell of each table row, so prose naming an order is not a listing.
local listed = {}
for l in (view .. "\n"):gmatch("([^\n]*)\n") do
    local o = l:match("^| *([0-9][0-9a-z-]*) *|")
    if o then listed[o] = true end
end
local function minus(a, b)
    local d = {}
    for k in pairs(a) do if not b[k] then d[#d + 1] = k end end
    table.sort(d)
    return d
end
local missing, stale = minus(live, listed), minus(listed, live)
local n_live = #minus(live, {})
if #missing > 0 or #stale > 0 then
    local msg = { "  why: " .. VIEW .. " is declared a filtered view of ACTIVE multi_cycle packets",
        "  (methodology/distributed-work.yaml -> long_running_packets.sub_queue_view).",
        "  remedy: add a row for each missing order and remove each stale one, in the same",
        "  commit as the change that moved it. The prose columns are editorial and",
        "  cannot be generated — that is why this checks membership, not rendering." }
    if #missing > 0 then
        msg[#msg + 1] = "  LIVE multi_cycle packets absent from " .. VIEW .. ":"
        for _, o in ipairs(missing) do msg[#msg + 1] = "    missing: " .. o end
    end
    if #stale > 0 then
        msg[#msg + 1] = "  Rows in " .. VIEW .. " naming no live multi_cycle packet (terminal or gone):"
        for _, o in ipairs(stale) do msg[#msg + 1] = "    stale:   " .. o end
    end
    log.raw(table.concat(msg, "\n"))
    verdict.emit("violation:long-running-view:missing=" .. #missing .. ":stale=" .. #stale, 1)
end
verdict.emit("ok:long-running-view:" .. n_live .. " live packets listed", 0)
