-- @env PATH HOME
-- @trace order:1465-ijv3, spec:spec-traceability, order:2322-a756
--
-- test-litmus-test-selector.lua — `run-litmus-test.sh --test litmus:<name>` runs EXACTLY ONE
-- bound test through the spec that binds it. Ported from the .sh of the same name (2322-a756).
--
--   1 --test <a> runs a and not b, and passes
--   2 a name no spec binds is refused:litmus-runner:test-not-bound:<name>, exit 3
--   3 CONTROL the same spec without --test runs both
--   4 the positional filter still fails loud on a test name (764-8m5j)
--   5 --test accepts the name without its prefix
--   6 --test with a different positional spec is refused, never merged
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-test-selector.lua
-- Verdict: ok:litmus-test-selector:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-test-selector")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/lt"); fs.mkdir(d.rel .. "/rt")
-- COMPOSED, never a literal name (721-77yu).
local L, SPEC = "lit" .. "mus", "spec-traceability"
local A, B = L .. ":sel-a", L .. ":sel-b"
fs.write(d.rel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 1465-ijv3\nspecs:\n- spec_id: " .. SPEC .. "\n  status: active\n  litmus_tests:\n  - "
    .. A .. "\n  - " .. B .. "\n  coverage_ratio: 100\n  last_verified: '2026-09-28'\n")
for _, t in ipairs{ "a", "b" } do
    fs.write(d.rel .. "/lt/litmus-sel-" .. t .. ".yaml", "name: " .. L .. ":sel-" .. t .. "\nspec: " .. SPEC .. "\nphase: pre-build\nseverity: high\nsize: instant\n"
        .. "description: >\n  probe\ncritical_path:\n  - step: \"probe " .. t .. '"\n    command: "echo sel-' .. t .. '-done"\n    timeout_ms: 20000\n    expected_behavior: "sel-' .. t .. '-done"\n')
end
local function run(...)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/run-litmus-test.sh", ... }, cwd = ROOT, timeout_ms = 120000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_LITMUS_BINDINGS = d.abs .. "/bindings.yaml",
            TILLANDSIAS_LITMUS_TESTS_DIR = d.abs .. "/lt", TILLANDSIAS_LITMUS_RUNTIME_DIR = d.abs .. "/rt", TILLANDSIAS_TIMING_LOG = d.abs .. "/timing.jsonl" } }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", ""):gsub("\r", "")
    return { rc = r.code, out = o, why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 900) }
end
local function did(x, name) return text.contains(x.out, "Executing " .. name) end

local x = run("--test", A)
T:arm("1 --test runs exactly that test and passes", x.rc == 0 and did(x, A) and not text.contains(x.out, B) and text.contains(x.out, "Total: 1 ")
    and text.contains(x.out, "Status: [PASS]"), x.why)
x = run("--test", L .. ":nope")
T:arm("2 an unbound name is refused with exit 3, naming the bindings file", x.rc == 3
    and text.contains("\n" .. x.out, "\nrefused:litmus-runner:test-not-bound:" .. L .. ":nope\n") and text.contains(x.out, "bindings.yaml"), x.why)
x = run(SPEC)
T:arm("3 CONTROL without --test both bound tests run", x.rc == 0 and did(x, A) and did(x, B) and text.contains(x.out, "Total: 2 "), x.why)
x = run(A)
T:arm("4 a test name as the positional filter still fails loud", x.rc ~= 0 and text.contains(x.out, "no litmus tests matched filter '" .. A .. "'"), x.why)
x = run("--test", "sel-b")
T:arm("5 --test accepts the name without its prefix", x.rc == 0 and did(x, B) and not did(x, A), x.why)
x = run("--test", A, "some-other-spec")
T:arm("6 --test with a different positional spec is refused with exit 3", x.rc == 3 and text.contains(x.out, "bound under spec " .. SPEC .. ", not some-other-spec")
    and not did(x, A), x.why)
T:finish()
