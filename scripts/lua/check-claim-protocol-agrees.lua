-- @env TILLANDSIAS_WORKER_SKILL TILLANDSIAS_COORD_SKILL
-- @read-env TILLANDSIAS_WORKER_SKILL TILLANDSIAS_COORD_SKILL
-- @trace spec:methodology-accountability
-- @trace order:943-unii, order:814-iyu7, order:888-vgs8
--
-- check-claim-protocol-agrees.lua — PORTED from check-claim-protocol-agrees.sh
-- (the shell-to-lua carried obligation, paid by 888-vgs8). Refuse a tree in
-- which the WORKER skill and the COORDINATOR skill specify different claim
-- mechanisms.
--
-- THE DEFECT THIS EXISTS FOR, measured 2026-08-30/31 (943-unii). Three sources
-- described claiming and one disagreed: the coordinator skill and
-- methodology/distributed-work.yaml said `set-field <order> status
-- in_progress`, pushed BEFORE the work; the worker skill said `append-event
-- <id> claim`, pushed WITH the work. `append-event` changes no status, and
-- "leased" means exactly `status: in_progress`, so the worker recipe claimed
-- nothing: packet 245 carried 43 claim events and stayed in the ready pool,
-- and on 2026-08-18 two hosts implemented 798-tk7b six minutes apart
-- (814-iyu7). The outlier was the one document every worker host executes
-- every cycle.
--
-- WHY A CROSS-DOCUMENT CHECK AND NOT A LINT. Each file was internally coherent
-- and reviewed fine on its own; nothing in the tree ever read the two
-- together, so the check has to be the comparison itself.
--
-- WHAT IT COMPARES. The `tillandsias-plan set-field … status in_progress`
-- recipe from each skill, reduced to its command SHAPE (placeholders,
-- quoting and line continuations collapsed), so rewording a `--reason`
-- string is free but changing the mechanism is not. Then the worker must
-- also state the two rules that make claiming SAFE: push the claim BEFORE
-- the work, and release (`set-field … status ready`) on exit.
--
-- Verdict grammar, one line on stdout, unchanged from the .sh:
--   ok:claim-protocol-agrees:<shape>            exit 0
--   violation:claim-protocol:<reason>           exit 1
--   blocked:skill-missing:<path>                exit 2

local function setting(name, default)
    local v = env.get(name)
    if v == nil or v == "" then return default end
    return v
end
local WORKER = setting("TILLANDSIAS_WORKER_SKILL", "skills/advance-work-from-plan/SKILL.md")
local COORD = setting("TILLANDSIAS_COORD_SKILL", "skills/meta-orchestration/SKILL.md")

local function read_or_block(path)
    local ok, body = pcall(fs.read, path)
    if not ok or type(body) ~= "string" then
        verdict.emit("blocked:skill-missing:" .. path, 2)
    end
    return body
end
local worker_body = read_or_block(WORKER)
local coord_body = read_or_block(COORD)

-- Reduce a file's claim recipe to a command shape:
--   - join backslash continuations
--   - keep the first `tillandsias-plan set-field ... status in_progress` line
--   - replace every <placeholder>, "$(...)", $var and "quoted string" with ARG
--   - collapse whitespace
local function claim_shape(body)
    local joined, carry = {}, nil
    for _, l in ipairs(text.lines(body)) do
        if carry ~= nil then
            l = carry .. " " .. l:gsub("^%s+", "")
            carry = nil
        end
        if l:sub(-1) == "\\" then
            carry = l:sub(1, -2)
        else
            joined[#joined + 1] = l
        end
    end
    if carry ~= nil then joined[#joined + 1] = carry end
    for _, l in ipairs(joined) do
        if l:find("tillandsias%-plan%s+set%-field.*status%s+in_progress") then
            local s = l
            s = s:gsub('"%$%([^)]*%)"', "ARG")
            s = s:gsub("%$%([^)]*%)", "ARG")
            s = s:gsub("<[^>]*>", "ARG")
            s = s:gsub('"[^"]*"', "ARG")
            s = s:gsub("'[^']*'", "ARG")
            s = s:gsub("%$[A-Za-z_][A-Za-z0-9_]*", "ARG")
            s = s:gsub("^%s+", "")
            s = s:gsub("%s+$", "")
            s = s:gsub("%s+", " ")
            return s
        end
    end
    return nil
end

local worker_shape = claim_shape(worker_body)
local coord_shape = claim_shape(coord_body)

if coord_shape == nil then
    verdict.emit("violation:claim-protocol:coordinator-has-no-set-field-claim-recipe", 1)
end
if worker_shape == nil then
    verdict.emit("violation:claim-protocol:worker-has-no-set-field-claim-recipe", 1)
end
if worker_shape ~= coord_shape then
    log.raw("  worker(" .. WORKER .. "):      " .. worker_shape)
    log.raw("  coordinator(" .. COORD .. "):  " .. coord_shape)
    verdict.emit("violation:claim-protocol:shapes-differ", 1)
end

-- The mechanism agreeing is not enough: the worker must also state the two
-- rules that make claiming SAFE. Both were absent while the divergence stood.
if not worker_body:lower():find("before the work", 1, true) then
    verdict.emit("violation:claim-protocol:worker-omits-push-claim-before-work", 1)
end
local releases = false
for _, l in ipairs(text.lines(worker_body)) do
    if l:find("set%-field.*status%s+ready") then releases = true break end
end
if not releases then
    verdict.emit("violation:claim-protocol:worker-omits-release-on-exit-recipe", 1)
end

verdict.ok("claim-protocol-agrees", worker_shape)
