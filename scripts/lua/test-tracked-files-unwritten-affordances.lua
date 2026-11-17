-- @env PATH
-- @trace order:1247-amcu, order:1063-363b, spec:methodology-accountability
--
-- test-tracked-files-unwritten-affordances.lua — every refusal of
-- scripts/check-tracked-files-unwritten.sh says WHY it refused and WHAT would make
-- it not a refusal (1247-amcu): labelled "  why:" / "  remedy:" lines on stderr
-- beside its unchanged stdout verdict, or, where the script already prints its
-- own explanatory stderr line, an `affordance-ok:` marker on the line above.
--
-- Four refusals are reached before any file is hashed, so they are RUN;
-- snapshot-empty and mktemp-failed need a broken host and are pinned
-- STATICALLY.
--
--   1 no arguments refuses usage with why and remedy;
--   2 an unknown mode refuses with why and remedy;
--   3 verify with no baseline refuses with why and remedy;
--   4 snapshot outside a git work tree (GIT_DIR names nothing) refuses;
--   5 STATIC: every verdict the script emits carries an _afford call on its
--     line or the line above, or an `affordance-ok:` marker on the line above.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tracked-files-unwritten-affordances.lua
-- Verdict: ok:tracked-files-unwritten-affordances:<n> arms | violation:tracked-files-unwritten-affordances:<arm>

local SUBJECT = "scripts/check-tracked-files-unwritten.sh"
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
refuses("1 no arguments refuses usage with why and remedy",
    { "bash", SUBJECT }, nil, "blocked:tracked-files-unwritten:usage")
refuses("2 an unknown mode refuses with why and remedy",
    { "bash", SUBJECT, "frobnicate", "x" }, nil, "blocked:tracked-files-unwritten:unknown-mode:frobnicate")
refuses("3 verify with no baseline refuses with why and remedy",
    { "bash", SUBJECT, "verify", "target/plan-scratch/tfu-no-such-baseline" }, nil,
    "blocked:tracked-files-unwritten:no-snapshot-at:target/plan-scratch/tfu-no-such-baseline")
refuses("4 snapshot outside a git work tree refuses with why and remedy",
    { "bash", SUBJECT, "snapshot", "target/plan-scratch/tfu-unused" }, { GIT_DIR = "/nonexistent-tfu-fixture" },
    "blocked:tracked-files-unwritten:not-a-git-repo")

-- 5 static: no verdict site without its affordance.
local src = fs.read(SUBJECT) or ""
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = (line:find('echo "refused:', 1, true) or line:find('echo "blocked:', 1, true)
        or line:find('echo "violation:', 1, true)) and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("_afford ", 1, true)
        and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("5 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

if #failed > 0 then
    verdict.emit("violation:tracked-files-unwritten-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:tracked-files-unwritten-affordances:" .. arms .. " arms", 0)
