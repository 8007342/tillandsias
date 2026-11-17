-- @env PATH
-- @trace order:1247-amcu, spec:meta-orchestration
--
-- test-openspec-pin-affordances.lua — every refusal of scripts/openspec-pin.sh
-- (the project's one openspec CLI pin) says WHY it refused and WHAT would make
-- it not a refusal, as labelled "  why:" / "  remedy:" lines on stderr beside
-- its unchanged stdout verdict (1247-amcu).
--
-- Hermetic: nothing reaches npm. The cache is a scratch dir (or a path that
-- cannot be created), and OPENSPEC_PIN_NPM is `false`, so an install fails at
-- once instead of downloading.
--
--   1 install of a non-version, bump with an unknown argument, an unwritable
--     cache and an npm that fails each refuse with the stdout verdict and why
--     and remedy on stderr;
--   2 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above, so a refusal added
--     later without one fails here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-openspec-pin-affordances.lua
-- Verdict: ok:openspec-pin-affordances:<n> arms | violation:openspec-pin-affordances:<arm>

local SUBJECT = "scripts/openspec-pin.sh"
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
local scratch = root .. "/target/plan-scratch/osp-afford-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", scratch } }

local function run(args, cache)
    local argv = { "bash", SUBJECT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 60000, env = {
        HOME = scratch, OPENSPEC_PIN_CACHE = cache or (scratch .. "/cache"), OPENSPEC_PIN_NPM = "false",
    } }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end

-- 1 the refusals that need no network.
local cases = {
    { "a non-version", { "install", "latest-please" }, nil, "refused:openspec-install:latest-please:not-a-version" },
    { "an unknown bump argument", { "bump", "--bogus" }, nil, "refused:openspec-bump:unknown-argument:--bogus" },
    { "an unwritable cache", { "install", "9.9.9" }, "/proc/osp-afford/cache", "refused:openspec-install:9.9.9:cache-unwritable" },
    { "an npm that fails", { "install", "9.9.9" }, nil, "refused:openspec-install:9.9.9:npm-install-failed" },
}
for _, c in ipairs(cases) do
    local code, so, se = run(c[2], c[3])
    arm("1 " .. c[1] .. " refuses with why and remedy",
        code == 1 and so:find(c[4], 1, true) ~= nil and afforded(se),
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
    verdict.emit("violation:openspec-pin-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:openspec-pin-affordances:" .. arms .. " arms", 0)
