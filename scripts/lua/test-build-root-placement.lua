-- @trace order:1802-fbld
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- test-build-root-placement.lua — arms of build-root-placement.lua on a fake layout.
--   1 MATCH    target on the fast root's device -> fast=yes, no warning
--   2 MISMATCH target on another device -> fast=no AND the bind-mount warning (red without the decider)
--   3 ABSENT   no fast root -> fast=no, no warning
--   4 LIVE     the real host answers with exactly one build-root: line
local SUBJECT = "scripts/lua/build-root-placement.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:build-root-placement-fixture:no-subject", 1, SUBJECT .. " does not exist (1802-fbld)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("build-root-placement-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
-- 1204-3s2s / 1096-p3tn: a hermetic fixture must not reach the host's metrics.
-- Every TILLANDSIAS_*_LOG the subject could write points into this scratch dir.
local SCRATCH = "target/plan-scratch/build-root-placement-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(SCRATCH)
local LOGENV = {
    TILLANDSIAS_TIMING_LOG = SCRATCH .. "/timing.jsonl",
    TILLANDSIAS_METRICS_LOG = SCRATCH .. "/metrics.jsonl",
    TILLANDSIAS_HEALTH_LOG = SCRATCH .. "/health.jsonl",
}
local function placement(args)
    local argv = { PLAN, "script", "run", SUBJECT, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000, env = LOGENV })
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local o = placement({ "--seam-mounted", "yes", "--seam-root-dev", "64775", "--seam-target-dev", "64775", "--seam-info", "xfs, raid0 md127, 913G free" })
arm("1 MATCH target on the fast root's device is fast=yes with no warning",
    o:find("fast=yes", 1, true) ~= nil and o:find("WARNING", 1, true) == nil, o)
o = placement({ "--seam-mounted", "yes", "--seam-root-dev", "64775", "--seam-target-dev", "42", "--seam-info", "xfs" })
arm("2 MISMATCH target on another device is fast=no and warns with the bind-mount remedy",
    o:find("fast=no", 1, true) ~= nil and o:find("WARNING", 1, true) ~= nil and o:find("bind", 1, true) ~= nil, o)
o = placement({ "--seam-mounted", "no", "--seam-root-dev", "0", "--seam-target-dev", "42" })
arm("3 ABSENT no fast root is fast=no and silent",
    o:find("fast=no", 1, true) ~= nil and o:find("WARNING", 1, true) == nil, o)
o = placement({})
local _, n = o:gsub("build%-root: target=", "")
arm("4 LIVE this host prints exactly one placement line", n == 1, o)
proc.run({ argv = { "rm", "-rf", SCRATCH }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:build-root-placement-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("build-root-placement-fixture", "4 arms")
