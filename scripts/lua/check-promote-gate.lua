-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN XDG_CONFIG_HOME GH_CONFIG_DIR
-- @trace order:2296-pn45, order:2252-ck7h, spec:ci-release
--
-- check-promote-gate.lua — may this exact release tag be promoted to stable? Only when
-- each of linux, darwin and windows has a smoke PASS record for THAT tag in the ledger,
-- and the land queue is idle (coordinator 2026-11-24, bundle landing phase 4).
-- scripts/promote-stable.sh asks it; it promotes nothing and writes nothing.
--
-- THE RECORD is an event of type `smoke-record` on the row `smoke-<tag, dots as dashes>`
-- (v56.11.23.1 -> smoke-v56-11-23-1), read FOLDED through `plan-events`. Its whole
-- summary is one line and must match in full, so prose that only mentions a tag and the
-- word PASS is never evidence (888-p3kt):
--
--   smoke <linux|darwin|windows> <tag> <verdict> regime=<r>
--     verdict  pass | partial:credential-unmeasured | fail:<what>
--     regime   where it ran, starting with the platform: linux-immutable:credential-warm
--   Keep it within 100 characters: plan-events cuts a longer summary, and a cut record is
--   malformed, which refuses. Where the evidence is goes in another event on the row.
--   tillandsias-plan append-event <row> smoke-record --summary-file <f> --ts <ISO> --agent <a> --host <h>
--
-- The LATEST record per platform decides: a later fail cancels an earlier pass, and a
-- malformed smoke-record on the row refuses (a record nobody can read is not absent).
-- partial:credential-unmeasured is never a pass by itself. It counts only for a platform
-- the promoter NAMES with --allow-unmeasured, and the verdict line names it again.
--
-- A stale checkout could hide a later fail, so trunk's head must be in HEAD; a local edit
-- could invent a pass, so plan/ must be clean.
--
--   ok:promote-gate:<tag>:linux=<v>,darwin=<v>,windows=<v>:queue=idle               rc 0
--   refused:promote-gate:<tag>:<why>[ <why>...]                                     rc 1
--     <platform>=missing|malformed|<verdict>   queue=<state>   ledger=stale|dirty
--   refused:promote-gate:usage                                                      rc 2
--   could-not-run:promote-gate:<why>                                                rc 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-promote-gate.lua -- <tag> [--allow-unmeasured p1,p2]

local PLATFORMS = { "linux", "darwin", "windows" }
local TAG, allow = nil, {}
local function usage() verdict.emit("refused:promote-gate:usage", 2) end
local i = 1
while i <= #arg do
    if arg[i] == "--allow-unmeasured" and arg[i + 1] then
        for p in arg[i + 1]:gmatch("[^,]+") do
            if p ~= "linux" and p ~= "darwin" and p ~= "windows" then usage() end
            allow[p] = true
        end
        i = i + 1
    elseif not TAG and arg[i]:match("^v%d+%.%d+%.%d+%.%d+$") then TAG = arg[i]
    else usage() end
    i = i + 1
end
if not TAG then usage() end

local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or "" end
if PLAN == "" then PLAN = "tillandsias-plan" end
local function run(argv)
    local ok, r = pcall(proc.run, { argv = argv, timeout_ms = 120000 })
    if not ok or r.status ~= "exited" then return -1, "" end
    return r.code, text.trim(r.stdout or "")
end
local function cnr(why) verdict.emit("could-not-run:promote-gate:" .. why, 3) end
local bad = {}

-- the ledger this checkout shows is trunk's
local c, TRUNK = run({ "gh", "api", "repos/{owner}/{repo}/git/ref/heads/linux-next", "--jq", ".object.sha" })
if c ~= 0 or not TRUNK:match("^%x+$") then cnr("trunk-head-unreadable") end
if run({ "git", "merge-base", "--is-ancestor", TRUNK, "HEAD" }) ~= 0 then bad[#bad + 1] = "ledger=stale" end
local dc, dirty = run({ "git", "status", "--porcelain", "--", "plan" })
if dc ~= 0 then cnr("git-status") end
if dirty ~= "" then bad[#bad + 1] = "ledger=dirty" end

-- the records
local ROW = "smoke-" .. TAG:gsub("%.", "-")
local _, events = run({ PLAN, "plan-events", ROW })
local got = {}
for _, l in ipairs(text.lines(events)) do
    local ty, ts, host, sum = l:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if ty == "smoke-record" then
        local p, t, v, r = sum:match("^smoke (%l+) (v[%d%.]+) ([%w:._-]+) regime=([%w:._-]+)$")
        local shaped = p and t == TAG and (p == "linux" or p == "darwin" or p == "windows")
            and (v == "pass" or v == "partial:credential-unmeasured" or v:match("^fail:[%w._-]+$"))
            and r:match("^" .. p .. "[:_-]") and ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
        if not shaped then
            out.line("  malformed smoke-record on " .. ROW .. ": " .. sum:sub(1, 160))
            got.malformed = true
        -- ties: the worse verdict wins, so an unordered pair never reads as a pass
        elseif not got[p] or ts > got[p].ts or (ts == got[p].ts and v ~= "pass") then
            got[p] = { ts = ts, v = v, host = host }
        end
    end
end
if got.malformed then bad[#bad + 1] = "record=malformed" end
local good = {}
for _, p in ipairs(PLATFORMS) do
    local g = got[p]
    if g and (g.v == "pass" or (g.v == "partial:credential-unmeasured" and allow[p])) then
        good[#good + 1] = p .. "=" .. g.v
        out.line("  " .. p .. " " .. g.v .. " (" .. g.host .. " " .. g.ts .. ")")
    else bad[#bad + 1] = p .. "=" .. (g and g.v or "missing") end
end

-- the queue, as the lander publishes it
local qc, QSHA = run({ "gh", "api", "repos/{owner}/{repo}/git/ref/tillandsias/queue/status", "--jq", ".object.sha" })
local mc, msg = -1, ""
if qc == 0 and QSHA:match("^%x+$") then mc, msg = run({ "gh", "api", "repos/{owner}/{repo}/git/commits/" .. QSHA, "--jq", ".message" }) end
local q = msg:match("^(queue:%l+)[: ]") or msg:match("^(queue:%l+)$")
if mc ~= 0 or not q then bad[#bad + 1] = "queue=unreadable"
elseif q ~= "queue:idle" then bad[#bad + 1] = "queue=" .. q:sub(7) end

if #bad > 0 then
    out.line("  why: promotion needs a smoke PASS record per platform for exactly " .. TAG .. " on row " .. ROW .. ", an idle land queue and trunk's own ledger")
    out.line("  remedy: run the missing smoke and append its smoke-record event (grammar in this script's header); update this checkout; wait for the queue. "
        .. "An unmeasured credential step counts only when named: --allow-unmeasured <platform>")
    verdict.emit("refused:promote-gate:" .. TAG .. ":" .. table.concat(bad, " "), 1)
end
verdict.ok("promote-gate", TAG .. ":" .. table.concat(good, ",") .. ":queue=idle")
