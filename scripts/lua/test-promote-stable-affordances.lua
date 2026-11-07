-- @env PATH
-- @trace order:1247-amcu, spec:ci-release
--
-- test-promote-stable-affordances.lua — every refusal of
-- scripts/promote-stable.sh says WHY it refused and WHAT would make it not a
-- refusal, as labelled "  why:" / "  remedy:" lines on stderr beside its
-- unchanged stdout verdict (1247-amcu).
--
-- ONLY the caller-error refusals are RUN, because they exit before the first
-- gh call: this fixture never reads or touches a GitHub release. With HOME
-- set to a scratch dir gh has no credentials even if a refusal were moved
-- later, so a mistake fails closed instead of promoting anything.
--
--   1 an unknown flag, a malformed tag and `demote` without --to each refuse
--     with the stdout verdict and why and remedy on stderr;
--   2 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above (the sites whose
--     own stderr lines already explain them), so a refusal added later
--     without one fails here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-promote-stable-affordances.lua
-- Verdict: ok:promote-stable-affordances:<n> arms | violation:promote-stable-affordances:<arm>

local SUBJECT = "scripts/promote-stable.sh"
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

local function afforded(err)
    return err:find("  why: %S") ~= nil and err:find("  remedy: %S") ~= nil
end

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local scratch = root .. "/target/plan-scratch/ps-afford-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", scratch } }

local function run(args)
    local argv = { "bash", SUBJECT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 60000,
        env = { HOME = scratch, GH_CONFIG_DIR = scratch, GH_TOKEN = "", GITHUB_TOKEN = "" } }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end

-- 1 caller errors.
local cases = {
    { "an unknown flag", { "v1.0.261102.1", "--bogus" }, "refused:bad-tag:--bogus" },
    { "a malformed tag", { "not-a-tag" }, "refused:bad-tag:" },
    { "demote without --to", { "demote", "v1.0.261102.1" }, "refused:missing-target:" },
}
for _, c in ipairs(cases) do
    local code, so, se = run(c[2])
    arm("1 " .. c[1] .. " refuses with why and remedy",
        code == 1 and so:find(c[3], 1, true) ~= nil and afforded(se),
        "rc=" .. tostring(code) .. " stdout=" .. so .. " stderr=" .. se)
end

-- 2 static: no verdict site without its affordance.
local src = fs.read(SUBJECT) or ""
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = (line:find('echo "refused:', 1, true) or line:find('echo "blocked:', 1, true)
        or line:find('echo "violation:', 1, true)) and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("2 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

proc.run{ argv = { "rm", "-rf", scratch } }
if #failed > 0 then
    verdict.emit("violation:promote-stable-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:promote-stable-affordances:" .. arms .. " arms", 0)
