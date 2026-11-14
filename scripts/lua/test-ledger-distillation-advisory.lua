-- @trace spec:versioning, spec:ci-release, order:914-nkc4, order:1879-5jkt
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-ledger-distillation-advisory.lua: 914-nkc4. The README release-ledger
-- distillation advisory reports when the table is over its own threshold,
-- stays quiet when it is not, and refuses rather than answering when it cannot
-- look. PORTED from scripts/test-ledger-distillation-advisory.sh with
-- check-ledger-distillation (1879-5jkt's carried shell-to-lua item).
--
-- The historical refs are the teeth. The live table sits at its threshold, so
-- a run against HEAD can only print ok:. The positive controls are real
-- commits whose README carried 19 and 24 rows, the state 914-nkc4 measured.
-- An arm whose ref is absent from this clone says so and is not counted.
--
-- The argument arms are 1218-25z3's: an unknown flag or a flag missing its
-- value examines nothing, and every run has a hard deadline, because
-- verifying a hang fix unbounded reproduces the hang in the verifier.
--
-- Verdict: ok:ledger-distillation-advisory:<n> or
-- refused:ledger-distillation-advisory:<failed>.
-- Usage: tillandsias-plan script run scripts/lua/test-ledger-distillation-advisory.lua

local NAME = "ledger-distillation-advisory"
local CHECK = "scripts/lua/check-ledger-distillation.lua"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run(NAME, "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
if not fs.exists(CHECK) then verdict.emit("refused:" .. NAME .. ":no-check", 1, CHECK .. " does not exist") end

local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end

-- Run the check with a hard deadline; return its runner status, exit code and
-- last stdout line.
local function run(args, deadline)
    local argv = { PLAN, "script", "run", CHECK, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = deadline or 20000 })
    local last = ""
    for _, l in ipairs(text.lines(r.stdout or "")) do if l ~= "" then last = l end end
    return r.status, r.code, last
end
local function starts(s, p) return s:sub(1, #p) == p end

-- ARM 1: at or under threshold is quiet.
local _, rc, o = run({ "--ref", "HEAD" })
if starts(o, "ok:ledger-distillation:") and rc == 0 then ok("ARM 1: a table at or under threshold reports ok (" .. o .. ")")
else bad("ARM 1: wanted ok:ledger-distillation:*, got '" .. o .. "' rc=" .. tostring(rc)) end

-- ARM 2+3: the measured over-threshold states report due, and exit 0 (ARM 7:
-- the advisory can never refuse a cut).
for _, ref in ipairs({ "v56.9.12.2", "66d615e3f~1" }) do
    if proc.run({ argv = { "git", "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, timeout_ms = 10000 }).code ~= 0 then
        out.line("skip: ARM for " .. ref .. ": ref not present in this clone")
    else
        local _, drc, d = run({ "--ref", ref })
        if starts(d, "due:ledger-distillation:") and d:find(" (advisory)", 1, true) and drc == 0 then
            ok("ARM: the over-threshold table at " .. ref .. " reports due and exits 0 (" .. d .. ")")
        else bad("ARM: " .. ref .. " carried an over-threshold table; wanted due: with exit 0, got '" .. d .. "' rc=" .. tostring(drc)) end
    end
end

-- The live table through the threshold (both directions), so the comparison
-- is exercised even in a clone without the historical refs.
local _, orc, over = run({ "--threshold", "0" })
local _, _, under = run({ "--threshold", "9999" })
if starts(over, "due:ledger-distillation:") and orc == 0 and starts(under, "ok:ledger-distillation:") then
    ok("the live table reports due past threshold 0 (exit 0) and ok under 9999")
else bad("threshold legs: over '" .. over .. "' rc=" .. tostring(orc) .. ", under '" .. under .. "'") end

-- ARM 4: cannot look is NOT zero.
local _, _, miss = run({ "--ref", "refs/heads/no-such-ref-914-nkc4" })
if starts(miss, "skip:ledger-distillation:no-readme:") then ok("ARM 4: an unreadable ref is skipped, not counted as zero rows")
else bad("ARM 4: wanted skip:ledger-distillation:no-readme:*, got '" .. miss .. "'") end

-- ARM 5: an unknown argument examines nothing.
local _, urc, u = run({ "--no-such-flag" })
if starts(u, "could-not-run:ledger-distillation:unknown-argument:") and urc == 3 then
    ok("ARM 5: an unknown argument refuses instead of answering about the default tree")
else bad("ARM 5: wanted could-not-run:...:unknown-argument:*, got '" .. u .. "' rc=" .. tostring(urc)) end

-- ARM 6: a flag missing its value refuses and does not hang. The deadline is
-- the assertion.
for _, f in ipairs({ "--ref", "--threshold" }) do
    local st, frc, fo = run({ f }, 10000)
    if st == "timed_out" then
        bad("ARM 6: '" .. f .. "' with no value HUNG")
    elseif starts(fo, "could-not-run:ledger-distillation:missing-value:") and frc == 3 then
        ok("ARM 6: '" .. f .. "' with no value refuses and terminates (" .. fo .. ")")
    else
        bad("ARM 6: '" .. f .. "' wanted could-not-run:...:missing-value:*, got '" .. fo .. "' rc=" .. tostring(frc))
    end
end

if failed == 0 then verdict.emit("ok:" .. NAME .. ":" .. passed, 0) end
verdict.emit("refused:" .. NAME .. ":" .. failed, 1)
