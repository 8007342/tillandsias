-- @trace order:1842-2q4g
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_GHOST_TRACE_ROOT
--
-- test-check-ghost-traces.lua — exit criterion of 1842-2q4g, on scratch trees.
--   1 CLEAN   a tree whose only trace names an existing spec passes
--   2 GHOST   adding `@trace spec:no-such-spec` is refused, the spec named
--             (pre-fix: no decider exists, so this arm cannot pass)
--   3 EXISTS  adding another trace to the EXISTING spec passes
--   4 ROSTER  the preflight roster sees the decider (build.sh fast lane binds it)
-- Usage: tillandsias-plan script run scripts/lua/test-check-ghost-traces.lua

local SUBJECT = "scripts/lua/check-ghost-traces.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:ghost-traces-fixture:no-subject", 1, SUBJECT .. " does not exist (1842-2q4g)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("ghost-traces-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/ghost-traces-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function tree(name, extra)
    local d = ROOT .. "/" .. REL .. "/" .. name
    fs.mkdir(d .. "/scripts")
    fs.mkdir(d .. "/openspec/specs/real-spec")
    fs.mkdir(d .. "/openspec/specs/ci-release") -- the copied script traces it
    fs.write(d .. "/openspec/specs/ci-release/spec.md", "# ci\n")
    fs.write(d .. "/scripts/trace-coverage.sh", fs.read("scripts/trace-coverage.sh"))
    fs.write(d .. "/openspec/specs/real-spec/spec.md", "# real\n")
    fs.write(d .. "/openspec/ghost-trace-baseline.txt", "# empty\n")
    fs.write(d .. "/scripts/a.sh", "# @trace spec:real-spec\n" .. (extra or ""))
    return d
end
local function decide(d)
    return proc.run({ argv = { PLAN, "script", "run", ROOT .. "/" .. SUBJECT }, cwd = ROOT,
        env = { TILLANDSIAS_GHOST_TRACE_ROOT = d }, timeout_ms = 60000 })
end

local r1 = decide(tree("clean"))
arm("1 CLEAN passes", r1.code == 0, (r1.stdout or ""):sub(1, 120))
local r2 = decide(tree("ghost", "# @trace spec:no-such-spec\n"))
local o2 = (r2.stdout or "") .. (r2.stderr or "")
arm("2 GHOST refused and named", r2.code ~= 0 and o2:find("spec:no-such-spec", 1, true) ~= nil, o2:sub(1, 200))
local r3 = decide(tree("exists", "# @trace spec:real-spec\n"))
arm("3 EXISTS passes", r3.code == 0, (r3.stdout or ""):sub(1, 120))
local rs = proc.run({ argv = { "grep", "-l", "_run_lua_decider \"" .. SUBJECT .. "\"", "build.sh" }, cwd = ROOT })
arm("4 ROSTER bound by a literal _run_lua_decider in build.sh", (rs.stdout or ""):find("build.sh", 1, true) ~= nil, rs.stdout)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL } })
if #failed > 0 then verdict.emit("violation:ghost-traces-fixture:" .. #failed .. " arm(s) failed", 1) end
verdict.emit("ok:ghost-traces-fixture:4 arms", 0)
