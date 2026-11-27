-- @env PATH HOME
-- @trace order:956-llei, order:2322-a756
--
-- test-litmus-retired-phase-skip.lua — a litmus test whose phase is `retired` runs ONLY under
-- an explicit --phase retired. Ported from the .sh of the same name (2322-a756). The default
-- phase filter is "all", and --diff-scope fails closed into it, so an escalated scoped run
-- executed every retired fixture. The retired probe FAILS LOUDLY if it runs, so skipped and
-- ran cannot be confused.
--
--   1 default filter: the retired probe is skipped with its reason and the suite passes
--   2 default filter: the live probe executed (a suite that skipped everything passes 1)
--   3 --phase retired: the retired probe executes and the suite fails
--
-- The REAL runner, over scratch bindings, tests, runtime dir and timing log.
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-retired-phase-skip.lua
-- Verdict: ok:litmus-retired-phase-skip:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-retired-phase-skip")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/lt"); fs.mkdir(d.rel .. "/rt")
-- COMPOSED, never a literal name (721-77yu).
local L, SPEC = "lit" .. "mus", "retired-phase-probe"
local function test(slug, phase, step, command, expected)
    fs.write(d.rel .. "/lt/litmus-" .. slug .. ".yaml", "name: " .. L .. ":" .. slug .. "\nspec: " .. SPEC .. "\nphase: " .. phase
        .. "\nsize: instant\nseverity: low\ndescription: >\n  fixture probe\ncritical_path:\n  - step: \"" .. step
        .. '"\n    command: "' .. command .. '"\n    timeout_ms: 5000\n    expected_behavior: "' .. expected .. '"\n')
end
fs.write(d.rel .. "/bindings.yaml", "specs:\n  - spec_id: " .. SPEC .. "\n    status: active\n    litmus_tests:\n      - " .. L .. ":phase-live\n      - " .. L .. ":phase-retired\n")
test("phase-live", "pre-build", "live step passes", "echo ok: live", "ok: live")
test("phase-retired", "retired", "retired step must not execute unless asked for", "echo RETIRED-PROBE-EXECUTED > '" .. d.abs .. "/ran'; exit 1", "never-matches")
local function run(...)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/run-litmus-test.sh", SPEC, ... }, cwd = ROOT, timeout_ms = 120000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_LITMUS_BINDINGS = d.abs .. "/bindings.yaml",
            TILLANDSIAS_LITMUS_TESTS_DIR = d.abs .. "/lt", TILLANDSIAS_LITMUS_RUNTIME_DIR = d.abs .. "/rt", TILLANDSIAS_TIMING_LOG = d.abs .. "/timing.jsonl" } }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 900)
end
local function ran() return fs.exists(d.rel .. "/ran") end

local rc, o, why = run()
T:arm("1 the default filter skips the retired probe with its reason and passes", rc == 0
    and text.contains(o, "Phase retired: runs only under --phase retired") and not ran(), why)
T:arm("2 the default filter executed the live probe", o:find("live step passes[^\n]*%[OK%]") ~= nil, why)
rc, o, why = run("--phase", "retired")
T:arm("3 --phase retired executes the retired probe and fails", rc ~= 0 and ran(), why)
T:finish()
