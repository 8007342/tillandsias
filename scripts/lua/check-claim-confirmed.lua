-- @trace order:1370-tjme, order:1140-d6ni, order:1493-d93i, order:2165-uu9j
-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-claim-confirmed.lua — after claiming an order, did THIS host win it?
-- Ported from scripts/check-claim-confirmed.sh (order 2165-uu9j); every verdict
-- line and exit code is the same. The fragments are read with yaml.parse, so the
-- one jq call per fragment the .sh carried (914-ahsy) is gone.
--
-- THE DEFECT THIS REPLACES. join-the-fleet §3 and advance-work-from-plan once
-- confirmed a claim with `tillandsias-plan next <role> | grep -c <order>` → 0.
-- ANY host's claim hides the row from `next`, so the LOSER of a claim race
-- reads 0 exactly as the winner does (776-jcf3, 2026-09-25: both hosts read
-- "confirmed"; push order, which the coordinator then used, is also wrong).
--
-- THE RULE. Read the row's status-field WRITES (the LWW `status:` channel that
-- `set-field` appends to plan/index.d/), ordered by their own `ts`. The claims
-- that count are the `in_progress` writes after the row's last non-in_progress
-- status. The EARLIEST of those holds the order. Push and commit time are never
-- consulted.
--
-- LIMIT, stated: `compact` folds fragments into the base and keeps only the
-- current value, so a race older than the last compaction cannot be re-judged.
--
-- 1493-d93i: THE CLAIM MUST BE ON ORIGIN. When the plan dir lives in a git
-- checkout with an origin, the upstream branch is fetched FROM ORIGIN and this
-- claim's own fragment must be in that tree. A plan dir in a repository with no
-- origin (the hermetic race fixtures) is judged on the fold alone.
--
-- USAGE: tillandsias-plan script run scripts/lua/check-claim-confirmed.lua -- <order> --host <host> [--plan-dir DIR]
--   (DIR must be inside this checkout: the script runtime's fs.* is repo-scoped)
-- OUTPUT (one line on stdout):
--   ok:claim-confirmed:<order>:<host>@<ts>                              exit 0
--   refused:claim-lost:<order>:<host>@<ts>:earlier=<host>@<ts>:<file>   exit 1
--   refused:no-live-claim:<order>:<host>[:held-by=<host>@<ts>]          exit 1
--   refused:claim-not-on-origin:<order>:<host>@<ts>:<file>:origin/<b>=<sha9>  exit 1
--   could-not-run:claim-origin-unreachable:<order>:<host>@<ts>:branch=<b>  exit 3
--     (the .sh printed unknown:…; the script runtime has no unknown: kind, and
--     could-not-run: keeps the meaning — undecided, exit 3, never a pass)
--   could-not-run:<reason>                                              exit 3

local ENV = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local function run(argv, cwd)
    return proc.run({ argv = argv, cwd = cwd, env = ENV, timeout_ms = 120000 })
end
local function say(line, code) verdict.emit(line, code) end
local function trim(s) return text.trim(s or "") end

local order, host, plan_dir = "", "", "plan"
local a = arg or {}
local i = 1
while a[i] ~= nil do
    local v = a[i]
    if v == "--host" then host = a[i + 1] or ""; i = i + 2
    elseif v == "--plan-dir" then plan_dir = a[i + 1] or ""; i = i + 2
    elseif v:sub(1, 1) == "-" then say("could-not-run:unknown-argument:" .. v, 3)
    else order = v; i = i + 1 end
end
if order == "" or host == "" then
    say("could-not-run:usage: check-claim-confirmed.lua -- <order> --host <host> [--plan-dir DIR]", 3)
end

local ROOT = trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout)
if ROOT == "" then say("could-not-run:not-inside-a-checkout", 3) end
-- fs.* takes repo-relative paths; external tools take absolute ones.
local rel_plan = plan_dir
if rel_plan:sub(1, #ROOT + 1) == ROOT .. "/" then rel_plan = rel_plan:sub(#ROOT + 2) end
if rel_plan:sub(1, 1) == "/" then say("could-not-run:plan-dir-outside-checkout:" .. plan_dir, 3) end
rel_plan = rel_plan:gsub("/+$", "")
local abs_plan = ROOT .. "/" .. rel_plan

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then PLAN = "tillandsias-plan" end

-- order -> packet_id, through the fold (the status row's third column).
local pid = nil
local st = run({ PLAN, "--index", abs_plan .. "/index.yaml", "status", order })
for _, l in ipairs(text.lines(st.stdout or "")) do
    local cols = text.split(l, "\t")
    if cols[1] == order and cols[3] and cols[3] ~= "" then pid = cols[3]; break end
end
if not pid then say("could-not-run:unresolved-order:" .. order, 3) end

-- Every status-field write for this packet in the overlay.
local writes = {}
local g = run({ "grep", "-rlF", "--include=*.yaml", "--", pid, abs_plan .. "/index.d" })
for _, path in ipairs(text.lines(g.stdout or "")) do
    local base = path:match("([^/]+)$")
    if base then
        local doc = yaml.parse(fs.read(rel_plan .. "/index.d/" .. base) or "") or {}
        for _, w in ipairs(type(doc.status) == "table" and doc.status or {}) do
            if type(w) == "table" and w.packet_id == pid and w.field == "status" then
                writes[#writes + 1] = { ts = tostring(w.ts or ""), host = tostring(w.host or ""),
                    value = tostring(w.value or ""), file = base }
            end
        end
    end
end
table.sort(writes, function(x, y)
    if x.ts ~= y.ts then return x.ts < y.ts end
    return x.file < y.file
end)

-- Claims after the last non-claim status write.
local live = {}
for _, w in ipairs(writes) do
    if w.value ~= "in_progress" then live = {} else live[#live + 1] = w end
end
local first, mine = live[1], nil
for _, w in ipairs(live) do if w.host == host then mine = w; break end end

if not mine then
    if first then say("refused:no-live-claim:" .. order .. ":" .. host .. ":held-by=" .. first.host .. "@" .. first.ts, 1) end
    say("refused:no-live-claim:" .. order .. ":" .. host, 1)
end

-- 1493-d93i: the claim must be on origin, not only in this checkout.
local repo = trim(run({ "git", "-C", abs_plan, "rev-parse", "--show-toplevel" }).stdout)
if repo ~= "" and run({ "git", "-C", repo, "remote", "get-url", "origin" }).code == 0 then
    local branch = trim(run({ "git", "-C", repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }).stdout)
    branch = branch:gsub("^origin/", "")
    if branch == "" or branch == "@{u}" then
        branch = trim(run({ "git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD" }).stdout)
    end
    local plan_real = trim(run({ "pwd", "-P" }, abs_plan).stdout)
    local repo_real = trim(run({ "pwd", "-P" }, repo).stdout)
    local relf = ""
    if plan_real:sub(1, #repo_real + 1) == repo_real .. "/" then
        relf = plan_real:sub(#repo_real + 2) .. "/index.d/" .. mine.file
    end
    local f = run({ "git", "-C", repo, "fetch", "-q", "origin", "refs/heads/" .. branch })
    local tip = f.code == 0 and trim(run({ "git", "-C", repo, "rev-parse", "FETCH_HEAD" }).stdout) or ""
    if tip == "" then
        log.raw("  the claim is in the local ledger, but origin could not be asked whether it has it; do not start work on an unverified claim")
        say("could-not-run:claim-origin-unreachable:" .. order .. ":" .. host .. "@" .. mine.ts .. ":branch=" .. branch, 3)
    end
    if relf == "" or run({ "git", "-C", repo, "cat-file", "-e", tip .. ":" .. relf }).code ~= 0 then
        log.raw("  the claim fragment exists only in this checkout: its push did not land. Push it (verify with git ls-remote origin), then re-run this check")
        say("refused:claim-not-on-origin:" .. order .. ":" .. host .. "@" .. mine.ts .. ":" .. mine.file
            .. ":origin/" .. branch .. "=" .. tip:sub(1, 9), 1)
    end
end

if first.host == host then say("ok:claim-confirmed:" .. order .. ":" .. host .. "@" .. mine.ts, 0) end
say("refused:claim-lost:" .. order .. ":" .. host .. "@" .. mine.ts .. ":earlier=" .. first.host .. "@" .. first.ts
    .. ":" .. first.file, 1)
