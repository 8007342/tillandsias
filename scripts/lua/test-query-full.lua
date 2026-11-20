-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2111-dd2m
--
-- test-query-full.lua — `tillandsias-plan query --full` returns the whole
-- FOLDED row, so a reader that needs row TEXT (exit_criteria, next_action,
-- owned_files) never hand-parses the ledger YAML.
--
-- WHY (2111-dd2m, measured 2026-11-19): a triage hand-parsed the YAML because
-- the --json projection carries no row text, and it MISSED 389 of 1378 ready
-- rows for three reasons, one example id each:
--   1004-7vcc  base plan/index.yaml nests packets under plan_index:
--   1001-7fd9  a base row the packets:-only parser never reached
--   141        a bare numeric order, which YAML parses as an int
-- The fold sees all three. These arms assert --full hands back their text.
--
-- Arms:
--   1  --full returns each example id WITH its exit_criteria text
--      (RED before 2111-dd2m: "unknown query constraint: --full", rc=2)
--   2  --full drops no row: its ready count equals the plain --json count
--   3  the plain --json projection still carries NO exit_criteria (the
--      contract callers rely on is unchanged; --full is opt-in)
--   4  --full given twice is refused (rc=2), never silently accepted
--
-- Verdict: ok:query-full:<n> arms | violation:query-full:<failed>-of-<n>
-- Usage: tillandsias-plan script run scripts/lua/test-query-full.lua

local function nonempty(s) return s ~= nil and s ~= "" end
local function ok(r) return r.status == "exited" and r.code == 0 end

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not nonempty(BIN) then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not nonempty(BIN) and fs.exists("target/release/tillandsias-plan") then
    local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
    if ok(top) then BIN = text.trim(top.stdout or "") .. "/target/release/tillandsias-plan" end
end
if not nonempty(BIN) then
    verdict.blocked("query-full", "no plan binary (set TILLANDSIAS_PLAN_BIN)")
end

local arms, fails = 0, 0
local function arm(name, cond, got)
    arms = arms + 1
    if cond then
        print("ok:   " .. name)
    else
        fails = fails + 1
        print("FAIL: " .. name .. " (got: " .. tostring(got) .. ")")
    end
end

local function query(extra)
    local argv = { BIN, "query", "--status", "ready", "--json", "--limit", "0" }
    for _, x in ipairs(extra) do argv[#argv + 1] = x end
    return proc.run({ argv = argv, timeout_ms = 120000 })
end

local full = query({ "--full" })
local plain = query({})
local full_rows = ok(full) and json.parse(full.stdout or "[]") or {}
local plain_rows = ok(plain) and json.parse(plain.stdout or "[]") or {}

local by_order = {}
for _, r in ipairs(full_rows) do by_order[tostring(r.order)] = r end

for _, id in ipairs({ "1004-7vcc", "1001-7fd9", "141" }) do
    local r = by_order[id]
    local crit = r and r.exit_criteria
    local has_text = type(crit) == "table" and #crit > 0 and type(crit[1]) == "string" and #crit[1] > 0
    arm("1: --full returns " .. id .. " with its exit_criteria text", has_text,
        ok(full) and (r and "row without exit_criteria" or "row absent") or text.trim(full.stderr or full.stdout or ""))
end

arm("2: --full drops no row (" .. #full_rows .. " vs " .. #plain_rows .. ")",
    ok(full) and #full_rows == #plain_rows and #plain_rows > 0, #full_rows)

local leaked = false
for _, r in ipairs(plain_rows) do
    if r.exit_criteria ~= nil then leaked = true break end
end
arm("3: the plain projection carries no exit_criteria", ok(plain) and not leaked, leaked)

local twice = query({ "--full", "--full" })
arm("4: --full twice is refused with rc=2", twice.status == "exited" and twice.code == 2, twice.code)

if fails > 0 then
    verdict.emit("violation:query-full:" .. fails .. "-of-" .. arms, 1)
end
verdict.emit("ok:query-full:" .. arms .. " arms", 0)
