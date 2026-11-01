-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_LANDED_REF
-- @trace order:1934-mxxc
--
-- check-ready-rows-with-landed-work.lua — REPORT-ONLY. Lists every row the
-- folded ledger still calls `ready` whose `work/<order>` ref already landed on
-- trunk (a `land(N): work/<order>` commit subject). Measured 2026-10-31 on
-- calmecacpilli: 8 such rows were ports landed weeks earlier, and 69 more
-- carried a landed ref. A landed ref is NOT completion (an epic lands in
-- parts), so this never refuses and never closes anything; it shows where to
-- look.
--
--   ok:ready-rows-with-landed-work:0                                   exit 0
--   advisory:ready-rows-with-landed-work:<n> — ... (advisory)          exit 0

local function nonempty(s) return s ~= nil and s ~= "" end
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not nonempty(BIN) then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not nonempty(BIN) then
    verdict.could_not_run("ready-rows-with-landed-work", "no-plan-binary — set TILLANDSIAS_PLAN_BIN")
end
local REF = env.get("TILLANDSIAS_LANDED_REF")
if not nonempty(REF) then REF = "origin/linux-next" end

local q = proc.run({ argv = { BIN, "query", "--status", "ready", "--json", "--limit", "0" }, timeout_ms = 120000 })
if q.status ~= "exited" or q.code ~= 0 then
    verdict.could_not_run("ready-rows-with-landed-work", "plan query failed: " .. (q.stderr or ""))
end
local rows = json.parse(q.stdout or "[]")

local g = proc.run({ argv = { "git", "log", "--format=%h %s", REF }, timeout_ms = 120000 })
if g.status ~= "exited" or g.code ~= 0 then
    verdict.could_not_run("ready-rows-with-landed-work", "git log " .. REF .. " failed")
end
local landed = {}
for _, l in ipairs(text.lines(g.stdout or "")) do
    local sha, order = l:match("^(%x+) land%(%d+%): work/(%d+%-%w+)")
    if sha and not landed[order] then landed[order] = sha end
end

local hits = {}
for _, r in ipairs(rows) do
    local o = tostring(r.order or "")
    if landed[o] then hits[#hits + 1] = { o, landed[o], r.kind or "?" } end
end
table.sort(hits, function(a, b) return a[1] < b[1] end)
for _, h in ipairs(hits) do
    out.line(string.format("ready row with a landed work/%s ref: %s kind=%s", h[1], h[2], h[3]))
end
if #hits == 0 then verdict.emit("ok:ready-rows-with-landed-work:0", 0) end
verdict.advisory("advisory:ready-rows-with-landed-work:" .. #hits ..
    " — verify each row's verifiable_closure on trunk and close it with evidence, or name what is still missing (advisory)")
