-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1144-jfr5, order:2031-dwwy
--
-- check-stale-ready-rows.lua — FIRST PASS of the stale-ready-row
-- reconciliation. Ported from check-stale-ready-rows.sh (paid as 2031-dwwy's
-- shell-to-lua carried obligation); same arguments, same output lines, exit 0.
--
-- A landed commit whose SUBJECT cites <order> as work — fix(<order>),
-- feat(<order>), close(<order>), test(<order>), record(<order>), style, docs,
-- refactor — while <order> still folds `ready` is a staleness CANDIDATE:
-- somebody believed they were working that row and the row was never moved.
-- MEASURED 2026-09-13: 1127-apa8 sat ready after e357f3f87
-- "fix(1125-wi4d, 1126-w8rq, 1127-apa8)" landed, and two hosts each spent a
-- cycle re-verifying it. No owned_files heuristic, and no false positive from a
-- commit that merely edited a file a row mentions.
--
-- A candidate is SURFACED, never closed: a commit can cite three orders and
-- complete two (e357f3f87 did exactly that). A host verifies the exit criteria
-- against the tree and appends the closing event with evidence.
--
-- NEGATIVE CONTROLS, pinned by scripts/lua/test-stale-ready-rows.lua:
-- claim(<order>) and file(<order>) are not work citations; an order mentioned
-- only in a commit BODY or without the (<order>) shape is not a candidate; an
-- order that does not fold ready is never reported.
--
-- Usage:
--   tillandsias-plan script run scripts/lua/check-stale-ready-rows.lua -- \
--       [--ref <rev>] [--orders-file <file>] [--repo <dir>] [--siblings 'ref ref'] [--trunk <ref>]
--     --ref          history to search (default: HEAD)
--     --orders-file  lines of <order>[<TAB><packet_id>] (default: the plan
--                    binary's ready rows); the fixture uses this to stay hermetic
--     --repo         run git in another checkout (fixture)
--     --siblings     space-separated refs whose unrelayed fragments may close a
--                    row (default: origin/osx-next origin/windows-next; "" disables)
--     --trunk        the ref those fragments are compared against (default origin/linux-next)
-- Output (stdout):
--   stale-candidate:<order>:<n-commits>:<newest-sha>                       one per candidate
--   stale-candidate:<order>:<n-commits>:<newest-sha>:closed-on:<branch>    the packet carries a
--       terminal status in that sibling branch's unrelayed fragments — relay it, never hand it
--   ok:stale-ready-rows:<candidates>/<ready-rows>:pass=cites-order
-- Exit 0 always (advisory; the coordination pass reads it); a usage error is
-- blocked:stale-ready-rows, exit 2, as the .sh's exit 2.
-- The plan binary is TILLANDSIAS_PLAN_BIN, TILLANDSIAS_SCRIPT_RUNNER_BIN, or
-- target/release/tillandsias-plan; with none the summary ends :no-plan-binary,
-- exactly as the .sh did when plan-binary-probe found none.

local function nonempty(s) return s ~= nil and s ~= "" end
local USAGE = "usage: check-stale-ready-rows.lua [--ref rev] [--orders-file file] [--repo dir] [--siblings 'ref ref'] [--trunk ref]"

local ref, orders_file, repo = "HEAD", nil, nil
local siblings, trunk = "origin/osx-next origin/windows-next", "origin/linux-next"
local a = arg or {}
local i = 1
while i <= #a do
    local k, v = a[i], a[i + 1]
    if v == nil then verdict.blocked("stale-ready-rows", USAGE) end
    if k == "--ref" then ref = v
    elseif k == "--orders-file" then orders_file = v
    elseif k == "--repo" then repo = v
    elseif k == "--siblings" then siblings = v
    elseif k == "--trunk" then trunk = v
    else verdict.blocked("stale-ready-rows", USAGE) end
    i = i + 2
end

local function git(args)
    local argv = { "git" }
    for _, x in ipairs(args) do argv[#argv + 1] = x end
    return proc.run({ argv = argv, cwd = repo, timeout_ms = 120000 })
end
local function ok(r) return r.status == "exited" and r.code == 0 end

-- orders: list of { order, packet_id-or-"" } in input order.
local orders = {}
if orders_file then
    if not fs.exists(orders_file) then verdict.blocked("stale-ready-rows", "--orders-file " .. orders_file .. " does not exist") end
    for _, l in ipairs(text.lines(fs.read(orders_file))) do
        if not l:match("^%s*#") and not l:match("^%s*$") then
            local o, p = l:match("^([^\t]*)\t(.*)$")
            orders[#orders + 1] = { o or l, p or "" }
        end
    end
else
    local BIN = env.get("TILLANDSIAS_PLAN_BIN")
    if not nonempty(BIN) then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
    if not nonempty(BIN) and fs.exists("target/release/tillandsias-plan") then
        local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
        if ok(top) then BIN = text.trim(top.stdout or "") .. "/target/release/tillandsias-plan" end
    end
    if not nonempty(BIN) then verdict.emit("ok:stale-ready-rows:0/0:pass=cites-order:no-plan-binary", 0) end
    local q = proc.run({ argv = { BIN, "query", "--status", "ready", "--json", "--limit", "0" }, timeout_ms = 120000 })
    if not ok(q) then verdict.emit("ok:stale-ready-rows:0/0:pass=cites-order:no-plan-binary", 0) end
    for _, r in ipairs(json.parse(q.stdout or "[]")) do
        orders[#orders + 1] = { tostring(r.order or ""), tostring(r.packet_id or "") }
    end
end

-- THE CLOSURE DIRECTION (yoga, 2026-09-13): a closure recorded on a platform
-- branch is invisible to plan_next everywhere else until the relay, and a
-- candidate handed in that window is closed twice (1140-d6ni). Read the
-- sibling branches' fragments that trunk does not have for a terminal status
-- per packet_id, so the candidate line can say closed-on. The first sibling
-- (in --siblings order) to close a packet is the one named.
local closed_on = {}
for sib in siblings:gmatch("%S+") do
    if ok(git({ "rev-parse", "--verify", "-q", sib })) then
        local d = git({ "diff", "--name-only", trunk .. "..." .. sib, "--", "plan/index.d" })
        for _, path in ipairs(ok(d) and text.lines(d.stdout or "") or {}) do
            if path ~= "" then
                local s = git({ "show", sib .. ":" .. path })
                local pid, f = nil, false
                for _, l in ipairs(ok(s) and text.lines(s.stdout or "") or {}) do
                    -- awk: /packet_id:/{pid=$NF} — the last field of the line
                    if l:find("packet_id:", 1, true) then pid = l:match("(%S+)%s*$") end
                    if l:match("^%s*field: status") then f = true end
                    local v = l:match("^%s*value: (%a+)")
                    if v == "completed" or v == "verified" or v == "archived" then
                        if f and pid and closed_on[pid] == nil then closed_on[pid] = sib end
                        f = false
                    end
                end
            end
        end
    end
end

-- One history walk, indexed by every order a work subject cites: 1213 ready
-- rows must not mean 1213 scans. A cited order is a run of non-[ ,] characters
-- inside the subject's FIRST parenthesis group, starting after "(", " " or ","
-- and ending at "," or ")" — the .sh's ([^)]*[ ,])?<order>[,)] — so 278 never
-- matches 1278 and 1001-aaaa never matches 1001-aaaab.
local WORK = { fix = true, feat = true, close = true, test = true, record = true, style = true, docs = true, refactor = true }
local g = git({ "log", "--format=%h %s", ref })
local cites = {}  -- order -> { n, newest }
for _, l in ipairs(ok(g) and text.lines(g.stdout or "") or {}) do
    local sha, kind, group, close = l:match("^(%x+) (%l+)%(([^)]*)(%)?)")
    if sha and WORK[kind] then
        local seen, pos = {}, 1
        while pos <= #group do
            local s, e = group:find("[^ ,]+", pos)
            if not s then break end
            local after = group:sub(e + 1, e + 1)
            if after == "," or (after == "" and close == ")") then
                local o = group:sub(s, e)
                if not seen[o] then
                    seen[o] = true
                    local c = cites[o]
                    if c then c.n = c.n + 1 else cites[o] = { n = 1, newest = sha } end
                end
            end
            pos = e + 1
        end
    end
end

local candidates, rows = 0, 0
for _, op in ipairs(orders) do
    local order, pid = op[1], op[2]
    if order ~= "" then
        rows = rows + 1
        local c = cites[order]
        if c then
            local line = "stale-candidate:" .. order .. ":" .. c.n .. ":" .. c.newest
            local sib = pid ~= "" and closed_on[pid] or nil
            if sib then line = line .. ":closed-on:" .. sib:gsub("^origin/", "") end
            out.line(line)
            candidates = candidates + 1
        end
    end
end

verdict.emit("ok:stale-ready-rows:" .. candidates .. "/" .. rows .. ":pass=cites-order", 0)
