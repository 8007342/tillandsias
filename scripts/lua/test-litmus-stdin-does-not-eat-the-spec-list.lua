-- @env PATH HOME
-- @trace order:956-llei, order:2322-a756
--
-- test-litmus-stdin-does-not-eat-the-spec-list.lua — a litmus step that READS STDIN must not
-- swallow the rest of its spec's bound test list. Ported from the .sh of the same name
-- (2322-a756). The runner iterates a spec's tests with a here-string on stdin; before the fix
-- a step containing `cat` drained it, every later test silently never ran, and the instant
-- sweep executed 1 of 29 ci-release tests on 2026-09-02 and reported PASS.
--
-- The REAL runner, over scratch bindings and tests, with its runtime dir and timing log in
-- scratch (the .sh used a temp root of symlinks).
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-stdin-does-not-eat-the-spec-list.lua
-- Verdict: ok:litmus-stdin-does-not-eat-the-spec-list:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-stdin-does-not-eat-the-spec-list")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/lt"); fs.mkdir(d.rel .. "/rt")
-- COMPOSED, never a literal name: check-litmus-pin-claims.sh reads one as a claim (721-77yu).
local L, SPEC = "lit" .. "mus", "stdin-probe"
local function test(slug, step, command, expected)
    fs.write(d.rel .. "/lt/litmus-" .. slug .. ".yaml", "name: " .. L .. ":" .. slug .. "\nspec: " .. SPEC
        .. "\nphase: pre-build\nsize: instant\nseverity: low\ndescription: >\n  fixture probe\ncritical_path:\n  - step: \"" .. step
        .. '"\n    command: "' .. command .. '"\n    timeout_ms: 5000\n    expected_behavior: "' .. expected .. '"\n')
end
fs.write(d.rel .. "/bindings.yaml", "specs:\n  - spec_id: " .. SPEC .. "\n    status: active\n    litmus_tests:\n      - " .. L .. ":stdin-eater\n      - " .. L .. ":stdin-second\n")
test("stdin-eater", "eat stdin", "cat >/dev/null; echo ok: ate-stdin", "ok: ate-stdin")
test("stdin-second", "second probe runs", "echo ok: SECOND-PROBE-RAN", "ok: SECOND-PROBE-RAN")

local r = T:run{ SH, ROOT .. "/scripts/run-litmus-test.sh", SPEC, "--phase", "pre-build", cwd = ROOT, timeout_ms = 120000, env_unset = { "TILLANDSIAS_*" },
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_LITMUS_BINDINGS = d.abs .. "/bindings.yaml",
        TILLANDSIAS_LITMUS_TESTS_DIR = d.abs .. "/lt", TILLANDSIAS_LITMUS_RUNTIME_DIR = d.abs .. "/rt", TILLANDSIAS_TIMING_LOG = d.abs .. "/timing.jsonl" } }
local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", "")
local why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 900)
T:arm("1 the stdin eater executed", text.contains(o, "Executing " .. L .. ":stdin-eater"), why)
T:arm("2 the second test executed after it, and passed", text.contains(o, "Executing " .. L .. ":stdin-second") and o:find("second probe runs[^\n]*%[OK%]") ~= nil, why)
T:arm("3 the suite passed over both", r.code == 0 and o:find("Total: 2 ") ~= nil, why)
T:finish()
