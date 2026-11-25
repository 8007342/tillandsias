-- @trace order:2118-ywk7, order:2332-5r8v, spec:ci-release
-- @env PATH HOME
--
-- test-runner-scratch-skips-sidecar.lua — priority:build-speed. A litmus-runner
-- start in a scratch project (a copy of scripts/, no crates/) under
-- target/plan-scratch cost ~20 s: 19.5 s was the runner's once-per-run sidecar
-- staging, build-sidecar.sh in a tree with no sidecar crate, where cargo walked
-- UP to the enclosing checkout's workspace. Under /tmp nothing encloses it, so
-- it failed fast (0.5 s), which is why only target/-scratch fixtures paid.
--
-- Arms, in a scratch project under target/plan-scratch (the T:scratch regime):
--   1  build-sidecar.sh refuses by name, exit 3, without compiling anything
--   2  a runner start does not stage the sidecar ("Staging router sidecar" absent)
--   3  CONTROL: this checkout HAS the crate, so the runner's staging condition
--      still holds here (the fix bounds staging; it does not remove it)
--
-- Usage: tillandsias-plan script run scripts/lua/test-runner-scratch-skips-sidecar.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("runner-scratch-skips-sidecar", "not inside a git checkout") end
-- 2332-5r8v: the plan binary as an absolute path. The variable handed on raw, when unset or
-- relative, resolved to nothing in the scratch project and every arm read as its own red.
local PLAN = require("common.fixture").plan_binary()
if PLAN == "" then verdict.could_not_run("runner-scratch-skips-sidecar", "no-plan-binary") end
local REL = "target/plan-scratch/ywk7-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/lt")
fs.mkdir(REL .. "/rt")
local PJ = W .. "/project"
run({ "git", "init", "-q", PJ })
run({ "cp", "-R", ROOT .. "/scripts", PJ .. "/scripts" })

local LIT = "litmus"
fs.write(REL .. "/bindings.yaml", "version: '1.0'\nspecs:\n- spec_id: spec-traceability\n  status: active\n"
    .. "  litmus_tests:\n  - " .. LIT .. ":ywk7-probe\n  coverage_ratio: 100\n")
fs.write(REL .. "/lt/litmus-ywk7-probe.yaml", "test: litmus-ywk7-probe\nsize: instant\nseverity: low\n"
    .. "phase: pre-build\ncritical_path:\n  - step: \"probe\"\n    command: \"echo probe-done\"\n"
    .. "    timeout_ms: 5000\n    expected_behavior: \"probe-done\"\n")

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local b = run({ "bash", PJ .. "/scripts/build-sidecar.sh" }, { cwd = PJ })
local be = b.stderr or ""
check("arm 1: build-sidecar.sh in a tree with no sidecar crate refuses by name, exit 3",
    b.code == 3 and text.contains(be, "could-not-run:build-sidecar:no-sidecar-crate:"),
    "rc=" .. tostring(b.code) .. " " .. be:sub(1, 200))

local r = run({ "bash", PJ .. "/scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build",
    "--size", "instant", "--compact" }, { cwd = PJ, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN,
        TILLANDSIAS_LITMUS_BINDINGS = W .. "/bindings.yaml",
        TILLANDSIAS_LITMUS_TESTS_DIR = W .. "/lt", TILLANDSIAS_LITMUS_RUNTIME_DIR = W .. "/rt" } })
local o = (r.stdout or "") .. (r.stderr or "")
check("arm 2: a runner start in the scratch project does not stage the sidecar",
    not text.contains(o, "Staging router sidecar") and text.contains(o, "Executing " .. LIT .. ":ywk7-probe"),
    (o:gsub("%s+", " ")):sub(1, 300))

local src = fs.read("scripts/run-litmus-test.sh") or ""
check("arm 3 (control): the runner still stages in a tree that has the crate, and this checkout has it",
    text.contains(src, '-f "$PROJECT_ROOT/crates/tillandsias-router-sidecar/Cargo.toml"')
        and fs.read("crates/tillandsias-router-sidecar/Cargo.toml") ~= nil,
    "the staging condition or the crate is gone")

run({ "rm", "-rf", W })
if failed > 0 then
    verdict.emit("violation:runner-scratch-skips-sidecar:" .. failed .. "-failed", 1)
end
verdict.ok("runner-scratch-skips-sidecar", passed .. "/" .. passed .. " (2118-ywk7)")
