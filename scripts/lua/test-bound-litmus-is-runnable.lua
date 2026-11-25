-- @env PATH HOME
-- @trace spec:ci-release, spec:methodology-accountability, order:958-b36m, order:660-ryhn, order:944-vim8, order:1096-p3tn, order:2362-2cfp
--
-- test-bound-litmus-is-runnable.lua — a litmus file the runner extracts no step from is refused,
-- by `run-litmus-test.sh --parse-only` and by the bindings gate when it is newly bound. Ported
-- from the .sh of the same name (2362-2cfp). The timing log is a scratch file.
--
--   1 a file with a step is accepted        2 one with none is refused, saying so
--   3 --parse-only executes nothing         4 a missing file is named
--   5 naming no file is refused             6 the gate refuses a newly bound unrunnable file
--   7 CONTROL and accepts a runnable one
--
-- Usage: tillandsias-plan script run scripts/lua/test-bound-litmus-is-runnable.lua
-- Verdict: ok:bound-litmus-is-runnable:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("bound-litmus-is-runnable")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local L, D = "lit" .. "mus:", T:scratch()
local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_TIMING_LOG = D.abs .. "/timing.jsonl" }
local function litmus(name, command)
    return "name: " .. L .. name .. "\nspec: ci-release\nphase: pre-build\ndescription: fixture\nseverity: low\nsize: instant\ncritical_path:\n  - step: \"a step the runner can extract\"\n    command: \""
        .. command .. "\"\n    timeout_ms: 1000\n    expected_behavior: \"ok: fixture\"\n"
end
local GOOD = litmus("fixture-one", "echo 'ok: fixture'")
local BAD = (GOOD:gsub("\ncritical_path:\n", "\nsteps:\n"))
fs.write(D.rel .. "/good.yaml", GOOD); fs.write(D.rel .. "/bad.yaml", BAD)
fs.write(D.rel .. "/side.yaml", litmus("fixture-side", "touch " .. D.abs .. "/executed; echo 'ok: fixture'"))
local function parse(...)
    local argv = { SH, ROOT .. "/scripts/run-litmus-test.sh", "--parse-only" }
    for _, f in ipairs{ ... } do argv[#argv + 1] = D.abs .. "/" .. f end
    local r = proc.run{ argv = argv, cwd = ROOT, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400)
end
local rc, o, why = parse("good.yaml")
T:arm("1 a file with a step is accepted, with its count", rc == 0 and o:find("ok:litmus%-parseable:[^\n]*1 step") ~= nil, why)
rc, o, why = parse("bad.yaml")
T:arm("2 a file with no extractable step is refused, saying so", rc ~= 0 and text.contains(o, "no parseable critical_path steps"), why)
rc, o, why = parse("side.yaml")
T:arm("3 --parse-only accepts a file and executes nothing", rc == 0 and not fs.exists(D.rel .. "/executed"), why)
rc, o, why = parse("absent.yaml")
T:arm("4 a missing file is named", rc ~= 0 and text.contains(o, "blocked:parse-only:missing"), why)
rc, o, why = parse()
T:arm("5 naming no file is refused", rc ~= 0 and text.contains(o, "blocked:parse-only:no files named"), why)

local g = T:git_repo()
for _, p in ipairs{ "openspec/litmus-tests", "openspec/specs/ci-release", "scripts" } do fs.mkdir(g.rel .. "/" .. p) end
fs.write(g.rel .. "/scripts/run-litmus-test.sh", fs.read("scripts/run-litmus-test.sh"))
T:must{ "chmod", "+x", g.abs .. "/scripts/run-litmus-test.sh" }
T:must{ "cp", "-r", ROOT .. "/scripts/lib", g.abs .. "/scripts/lib" }
local BIND = "version: \"1.0\"\nspecs:\n- spec_id: ci-release\n  status: active\n  litmus_tests:"
fs.write(g.rel .. "/openspec/litmus-bindings.yaml", BIND .. " []\n")
fs.write(g.rel .. "/openspec/specs/ci-release/spec.md", "# spec: ci-release\n")
fs.write(g.rel .. "/openspec/litmus-tests/unbound-grandfathered.txt", "")
T:must{ "git", "-C", g.abs, "add", "-A" }; T:must{ "git", "-C", g.abs, "commit", "-qm", "base" }; T:must{ "git", "-C", g.abs, "branch", "-f", "base-ref" }
fs.write(g.rel .. "/openspec/litmus-bindings.yaml", BIND .. "\n  - " .. L .. "fixture-one\n")
local function gate(body)
    fs.write(g.rel .. "/openspec/litmus-tests/litmus-fixture-one.yaml", body)
    local e = { LITMUS_BINDINGS_ROOT = g.abs, TILLANDSIAS_LITMUS_BIND_BASE = "base-ref" }
    for k, v in pairs(E) do e[k] = v end
    local r = proc.run{ argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/check-litmus-bindings.lua" }, cwd = g.abs, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local out = (r.stdout or "") .. (r.stderr or "")
    return r.code, out, "rc=" .. tostring(r.code) .. " " .. out:sub(1, 400)
end
rc, o, why = gate(BAD)
T:arm("6 the gate refuses a newly bound file with no step", rc ~= 0 and text.contains(o, "violation:bound-but-unrunnable"), why)
rc, o, why = gate(GOOD)
T:arm("7 CONTROL and accepts a runnable one", rc == 0, why)
T:finish()
