-- @env PATH
-- @trace order:1247-amcu, spec:inference-container
--
-- test-dev-inference-ensure-affordances.lua — every refusal of
-- scripts/dev-inference-ensure.sh (the dev host's inference engine for the
-- expert system) says WHY it refused and WHAT would make it not a refusal, as
-- labelled "  why:" / "  remedy:" lines on stderr beside its unchanged stdout
-- verdict (1247-amcu).
--
-- Most of its refusals sit behind a podman start, a download or a model pull,
-- which a hermetic fixture must not perform; those are pinned STATICALLY. The
-- one refusal reachable with no side effect is RUN: the macos-native lane
-- (TILLANDSIAS_DEV_INFERENCE_LANE_OVERRIDE, the seam 1249-xngp added for
-- test-dev-inference-lane.lua) on a closed port installs nothing and refuses.
--
--   1 the macos-native lane with no engine refuses blocked:no-engine with why
--     and remedy;
--   2 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above, so a refusal added
--     later without one fails here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-dev-inference-ensure-affordances.lua
-- Verdict: ok:dev-inference-ensure-affordances:<n> arms | violation:dev-inference-ensure-affordances:<arm>

local SUBJECT = "scripts/dev-inference-ensure.sh"
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
local scratch = root .. "/target/plan-scratch/die-afford-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", scratch } }

-- 1 macos-native, nothing listening: refuses, installs nothing.
local r = proc.run{ argv = { "bash", SUBJECT }, timeout_ms = 60000, env = {
    HOME = scratch, TILLANDSIAS_DEV_INFERENCE_HOME = scratch .. "/state",
    TILLANDSIAS_DEV_INFERENCE_LANE_OVERRIDE = "macos-native",
    TILLANDSIAS_DEV_INFERENCE_PORT = "9",
} }
local so, se = text.trim(r.stdout or ""), r.stderr or ""
arm("1 macos-native with no engine refuses no-engine with why and remedy",
    r.code == 1 and so:find("blocked:no-engine:macos-native", 1, true) ~= nil and afforded(se),
    "rc=" .. tostring(r.code) .. " stdout=" .. so .. " stderr=" .. se)

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
    verdict.emit("violation:dev-inference-ensure-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:dev-inference-ensure-affordances:" .. arms .. " arms", 0)
