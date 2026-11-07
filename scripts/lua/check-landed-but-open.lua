-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1367-emjg, order:1483-8zct, order:1270-5mz8
--
-- check-landed-but-open.lua — list every order cited by a CODE-landing commit on
-- trunk whose ledger row is still open, so "implemented but never closed" is a
-- count rather than an impression. Ported from check-landed-but-open.sh
-- (shell-to-lua, paid by 1270-5mz8); the grammar is unchanged.
--
-- WHY. Measured 2026-09-23: of 177 orders cited in code-landing commits over ten
-- days, 21 (12%) still carried ready, in_progress or implemented. Real work
-- landed and the row was never flipped, so it kept competing in the queue and
-- inflated the open count the operator reads as "all incomplete". Found again
-- 2026-09-28: 920-tqhs sat `ready` a month after relay 1425-t9v9 landed it.
--
-- WHAT COUNTS
--   a landing  a NON-MERGE commit reachable from --ref (default origin/linux-next)
--              within --since (default "10 days ago") that touches at least one
--              path OUTSIDE plan/, openspec/, docs/ and cheatsheets/. A commit
--              that only edits the plan, the SPEC or documentation citing an
--              order is not a landing (1483-8zct: spec-only commits used to
--              count, so 1438-pk9j was listed as landed-but-open);
--   an order   every NNN-xxxx / NNNN-xxxx token in that commit's SUBJECT. A body
--              cites orders as CONTEXT; --cite message restores the wide read;
--   open       the row's current status is ready, pending, in_progress or
--              implemented.
-- Orders the ledger does not know are skipped. Each suspect is listed once,
-- with the NEWEST landing that cites it.
--
-- ADVISORY BY DESIGN: exit 0 always. The list is where the coordinator looks,
-- not a gate.
--
-- USAGE  tillandsias-plan script run scripts/lua/check-landed-but-open.lua --
--          [--ref R] [--since S] [--cite subject|message] [--status-file F]
--   --status-file  "order status" lines instead of asking the plan binary
--                  (fixtures)
-- OUTPUT suspect:<order>:<status>:<landing-sha12> <subject> ... then
--        summary:landed-but-open:<n> window=<since> ref=<ref> cite=<c> landings=<m> orders=<k>
--        (<n> always equals the number of suspect lines), then the verdict
--        ok:landed-but-open:<n> (skip:landed-but-open:<why> when it cannot run).

local function summary0(why)
    out.line("summary:landed-but-open:0 could-not-run=" .. why)
    verdict.emit("skip:landed-but-open:" .. why, 0)
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then summary0("not-a-git-repo") end

local REF, SINCE, STATUS_FILE, CITE = "origin/linux-next", "10 days ago", "", "subject"
local argv = arg or {}
local i = 1
while i <= #argv do
    local a = argv[i]
    if a == "--ref" then REF = argv[i + 1]
    elseif a == "--since" then SINCE = argv[i + 1]
    elseif a == "--status-file" then STATUS_FILE = argv[i + 1]
    elseif a == "--cite" then CITE = argv[i + 1]
    else
        verdict.emit("refused:landed-but-open:usage:unknown-argument:" .. a
            .. " (usage: [--ref R] [--since S] [--cite subject|message] [--status-file F])", 2)
    end
    if argv[i + 1] == nil then
        verdict.emit("refused:landed-but-open:usage:" .. a .. "-needs-a-value", 2)
    end
    i = i + 2
end

local function git(args)
    local full = { "git" }
    for _, x in ipairs(args) do full[#full + 1] = x end
    return proc.run({ argv = full, cwd = ROOT, timeout_ms = 120000 })
end

if git({ "rev-parse", "--verify", "-q", REF }).code ~= 0 then summary0("unknown-ref:" .. REF) end

-- order -> status
local status = {}
local function add_status_line(l)
    local o, s = l:match("^(%S+)%s+(%S+)")
    if o then status[o] = s end
end
if STATUS_FILE ~= "" then
    -- fs.read is confined to the repository; a fixture's status file lives in its scratch dir.
    local sf = proc.run({ argv = { "cat", STATUS_FILE }, timeout_ms = 30000 })
    for _, l in ipairs(text.lines(sf.stdout or "")) do add_status_line(l) end
else
    local BIN = env.get("TILLANDSIAS_PLAN_BIN")
    if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
    if BIN == nil or BIN == "" then BIN = "tillandsias-plan" end
    local q = proc.run({ argv = { BIN, "query", "--json", "--limit", "1000000" }, cwd = ROOT, timeout_ms = 300000 })
    if q.code ~= 0 or q.stdout == nil or q.stdout == "" then summary0("no-plan-binary") end
    local rows = json.parse(q.stdout)
    for _, r in ipairs(rows or {}) do
        if r.order ~= nil and r.status ~= nil then status[tostring(r.order)] = tostring(r.status) end
    end
end

-- landings: non-merge commits in the window touching something outside the
-- plan, the spec and the docs (1483-8zct)
local shas = git({ "log", "--no-merges", "--since=" .. SINCE, "--format=%H", REF })
local landings = 0
local newest, order_list = {}, {}
for _, sha in ipairs(text.lines(shas.stdout or "")) do
    sha = text.trim(sha)
    if sha ~= "" then
        local files = git({ "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", sha })
        local nonplan = false
        for _, f in ipairs(text.lines(files.stdout or "")) do
            if f ~= "" and not text.is_match(f, "^(plan|openspec|docs|cheatsheets)/") then
                nonplan = true
                break
            end
        end
        if nonplan then
            landings = landings + 1
            local msg = git({ "log", "-1", "--format=" .. (CITE == "message" and "%B" or "%s"), sha }).stdout or ""
            local seen, cited = {}, {}
            -- a token bounded by a non [0-9A-Za-z-] character or the line edge
            for _, line in ipairs(text.lines(msg)) do
                local padded = " " .. line .. " "
                for o in padded:gmatch("[^%w%-](%d%d%d%d?%-[a-z0-9][a-z0-9][a-z0-9][a-z0-9])%f[^%w%-]") do
                    if not seen[o] then
                        seen[o] = true
                        cited[#cited + 1] = o
                    end
                end
            end
            -- sorted within a commit, as the .sh's `sort -u` listed them
            table.sort(cited)
            for _, o in ipairs(cited) do
                -- git log is newest-first, so the first landing seen wins
                if newest[o] == nil then
                    newest[o] = sha
                    order_list[#order_list + 1] = o
                end
            end
        end
    end
end

local n = 0
for _, o in ipairs(order_list) do
    local st = status[o]
    if st == "ready" or st == "pending" or st == "in_progress" or st == "implemented" then
        local sha = newest[o]
        local subj = text.trim(git({ "log", "-1", "--format=%s", sha }).stdout or "")
        out.line(string.format("suspect:%s:%s:%s %s", o, st, sha:sub(1, 12), subj:sub(1, (utf8.offset(subj, 101) or (#subj + 1)) - 1)))
        n = n + 1
    end
end
out.line(string.format("summary:landed-but-open:%d window=%s ref=%s cite=%s landings=%d orders=%d",
    n, (SINCE:gsub(" ", "-")), REF, CITE, landings, #order_list))
verdict.emit("ok:landed-but-open:" .. n, 0)
