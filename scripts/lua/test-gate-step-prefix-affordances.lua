-- @env PATH
-- @trace order:1247-amcu, order:1162-qbrx, spec:methodology-accountability
--
-- test-gate-step-prefix-affordances.lua — every refusal of
-- scripts/allocate-gate-step-prefix.sh says WHY it refused and WHAT would make
-- it not a refusal (1247-amcu): labelled "  why:" / "  remedy:" lines on stderr
-- beside its unchanged stdout verdict, or, where the script already prints its
-- own explanatory stderr line, an `affordance-ok:` marker on the line above.
--
-- The four usage refusals are reached before the script reads or moves a step,
-- so they are RUN; no-gap / overflow sit behind a real collision and are pinned
-- STATICALLY.
--
--   1 an unknown flag refuses usage with why and remedy;
--   2 a missing --base refuses usage with why and remedy;
--   3 outside a git checkout (GIT_DIR names nothing) refuses with why and remedy;
--   4 a --base that resolves to no commit refuses usage with why and remedy;
--   5 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-prefix-affordances.lua
-- Verdict: ok:gate-step-prefix-affordances:<n> arms | violation:gate-step-prefix-affordances:<arm>

local SUBJECT = "scripts/allocate-gate-step-prefix.sh"
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

local function refuses(name, argv, env, want)
    local r = proc.run{ argv = argv, timeout_ms = 30000, env = env }
    local so, se = text.trim(r.stdout or ""), r.stderr or ""
    arm(name, r.code == 2 and so:find(want, 1, true) ~= nil and afforded(se),
        "rc=" .. tostring(r.code) .. " stdout=" .. so .. " stderr=" .. se)
end

refuses("1 an unknown flag refuses usage with why and remedy",
    { "bash", SUBJECT, "--frobnicate" }, nil, "refused:gate-step-prefix:usage:--frobnicate")
refuses("2 a missing --base refuses usage with why and remedy",
    { "bash", SUBJECT }, nil, "refused:gate-step-prefix:usage:--base <ref> is required")
refuses("3 outside a git checkout refuses with why and remedy",
    { "bash", SUBJECT, "--base", "HEAD" }, { GIT_DIR = "/nonexistent-gate-step-prefix-fixture" },
    "refused:gate-step-prefix:not-a-git-checkout")
refuses("4 an unresolvable --base refuses usage with why and remedy",
    { "bash", SUBJECT, "--base", "refs/heads/no-such-ref-gate-step-prefix-fixture", "--dry-run" }, nil,
    "refused:gate-step-prefix:usage:refs/heads/no-such-ref-gate-step-prefix-fixture does not resolve")

-- 5 static: no verdict site without its affordance.
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
arm("5 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

if #failed > 0 then
    verdict.emit("violation:gate-step-prefix-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:gate-step-prefix-affordances:" .. arms .. " arms", 0)
