-- @env PATH HOME
-- @trace order:1247-amcu, spec:meta-orchestration
--
-- test-select-work-batch-affordances.lua — every refusal of
-- scripts/select-work-batch.sh (the batch selector every worker cycle runs)
-- says WHY it refused and WHAT would make it not a refusal, as labelled
-- "  why:" / "  remedy:" lines on stderr beside its unchanged stdout verdict
-- (1247-amcu, the operator ruling of 2026-09-17).
--
--   1 an unknown argument, a bad --role and a bad --budget each refuse with
--     the stdout verdict their callers parse, plus why and remedy on stderr;
--   2 the stated remedies are EXECUTED: the role first and --budget 1 clear
--     their refusals (whatever the run says next, it is not that refusal);
--   3 TILLANDSIAS_PLAN_BIN naming a binary that does not run refuses
--     no-plan-binary with why and remedy, and unsetting it, as the remedy
--     says, clears that refusal;
--   4 STATIC: every refusal the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above, so a refusal
--     added later without one fails here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-select-work-batch-affordances.lua
-- Verdict: ok:select-work-batch-affordances:<n> arms | violation:select-work-batch-affordances:<arm>

local SUBJECT = "scripts/select-work-batch.sh"
local arms, failed = 0, {}

local function arm(name, cond, detail)
    if cond then
        arms = arms + 1
        out.line("ok:   " .. name)
    else
        failed[#failed + 1] = name
        out.line("FAIL: " .. name .. " — " .. tostring(detail))
    end
end

local function run(args, env)
    local argv = { "bash", SUBJECT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, env = env or {}, timeout_ms = 120000 }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end

local function first_line(s) return s:match("^[^\n]*") or "" end
local function afforded(err)
    return err:find("\n?  why: %S") ~= nil and err:find("\n  remedy: %S") ~= nil
end

-- 1 caller errors refuse with the parsed verdict plus why and remedy.
local cases = {
    { "unknown argument", { "linux", "--bogus" }, "refused:bad-role:unknown argument --bogus" },
    { "bad role", { "solaris" }, "refused:bad-role:solaris" },
    { "budget not a number", { "linux", "--budget", "many" }, "refused:bad-role:budget must be a positive integer" },
    { "budget zero", { "linux", "--budget", "0" }, "refused:bad-role:budget must be >= 1" },
}
for _, c in ipairs(cases) do
    local code, so, se = run(c[2])
    arm("1 " .. c[1] .. " refuses with why and remedy",
        code == 1 and first_line(so):sub(1, #c[3]) == c[3] and afforded(se),
        "rc=" .. tostring(code) .. " stdout=" .. so .. " stderr=" .. se)
end

-- 2 the remedies clear their refusals.
local _, so_role = run({ "linux", "--budget", "1" })
arm("2 the role first and --budget 1 clear bad-role", not so_role:find("refused:bad-role", 1, true), so_role)

-- 3 a plan binary that does not run.
local code3, so3, se3 = run({ "linux" }, { TILLANDSIAS_PLAN_BIN = "/nonexistent/tillandsias-plan" })
arm("3 a non-running TILLANDSIAS_PLAN_BIN refuses no-plan-binary with why and remedy",
    code3 == 1 and so3:find("refused:no-plan-binary:TILLANDSIAS_PLAN_BIN=", 1, true) ~= nil and afforded(se3),
    "rc=" .. tostring(code3) .. " stdout=" .. so3 .. " stderr=" .. se3)
local _, so3b = run({ "linux", "--budget", "1" })
arm("3 unsetting it, as the remedy says, clears no-plan-binary", not so3b:find("refused:no-plan-binary", 1, true), so3b)

-- 4 static: no refusal site without its affordance.
local src = fs.read(SUBJECT) or ""
local prev, bare = "", {}
local n = 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = line:find('echo "refused:', 1, true) and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("4 every refusal site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare refusal lines: " .. table.concat(bare, ","))

if #failed > 0 then
    verdict.emit("violation:select-work-batch-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:select-work-batch-affordances:" .. arms .. " arms", 0)
