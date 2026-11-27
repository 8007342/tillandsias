-- @env PATH HOME
-- @trace order:2310-eji3, order:2308-irfp
--
-- test-litmus-bare-plan-binary.lua — a litmus step that calls a bare `tillandsias-plan` gets
-- the binary the runner resolved. On a host with none on PATH (yolanda, msys) every such step
-- was rc 127; with a stale one on PATH it tested the wrong binary. Real runner, scratch
-- bindings, tests and runtime dir.
--
--   1 NONE    none on PATH: the bare call reaches the resolved binary
--   2 STALE   another on PATH first: the bare call still reaches the resolved one
--   3 COPY    `cp "$(command -v tillandsias-plan)"` yields a runnable copy
--   4 OWNPATH CONTROL a step that sets its own PATH finds none
--   5 REFRESH a run after another binary's run reaches its own, never the old link
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-bare-plan-binary.lua
-- Verdict: ok:litmus-bare-plan-binary:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-bare-plan-binary")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local d = T:scratch()
for _, p in ipairs{ "lt", "rt", "stale" } do fs.mkdir(d.rel .. "/" .. p) end
-- COMPOSED, never a literal name (721-77yu).
local L, SPEC = "lit" .. "mus", "bare-plan-probe"
fs.write(d.rel .. "/stale/tillandsias-plan", "#!/bin/sh\necho STALE-BINARY\n")
T:must{ "chmod", "+x", d.abs .. "/stale/tillandsias-plan" }
local function id(bin) return text.trim((proc.run{ argv = { bin, "build-id" }, timeout_ms = 60000 }).stdout or "") end
local ID = id(PLAN)
if ID == "" then T:refuse("no-build-id") end

-- PATH without any directory that holds a tillandsias-plan; `first` goes in front.
local FILTER = [==[
out=""; first=$1; runner=$2; shift 2
IFS=:; for p in $PATH; do
  [ -e "$p/tillandsias-plan" ] || [ -e "$p/tillandsias-plan.exe" ] || out="${out:+$out:}$p"
done; unset IFS
[ -z "$first" ] || out="$(cd "$first" && pwd):$out"
PATH="$out"; export PATH
exec bash "$runner" "$@" </dev/null
]==]
local function run(command, first, plan)
    fs.write(d.rel .. "/bindings.yaml", "specs:\n  - spec_id: " .. SPEC .. "\n    status: active\n    litmus_tests:\n      - " .. L .. ":bare-plan\n")
    fs.write(d.rel .. "/lt/litmus-bare-plan.yaml", "name: " .. L .. ":bare-plan\nspec: " .. SPEC .. "\nphase: pre-build\nsize: instant\nseverity: low\n"
        .. 'description: >\n  fixture probe\ncritical_path:\n  - step: "bare call"\n    command: "' .. command .. '"\n    timeout_ms: 30000\n    expected_behavior: "ok:' .. ID .. '"\n')
    local r = T:run{ SH, "-s", "--", first or "", ROOT .. "/scripts/run-litmus-test.sh", SPEC, "--phase", "pre-build", cwd = ROOT, stdin = FILTER, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = plan, TILLANDSIAS_LITMUS_BINDINGS = d.abs .. "/bindings.yaml",
            TILLANDSIAS_LITMUS_TESTS_DIR = d.abs .. "/lt", TILLANDSIAS_LITMUS_RUNTIME_DIR = d.abs .. "/rt", TILLANDSIAS_TIMING_LOG = d.abs .. "/timing.jsonl" },
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", "")
    return r.code == 0 and o:find("bare call[^\n]*%[OK%]") ~= nil, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 1200)
end
local BARE = "echo ok:$(tillandsias-plan build-id)"
local ok, why = run(BARE, nil, PLAN)
T:arm("1 NONE with none on PATH a bare call reaches the resolved binary", ok, why)
ok, why = run(BARE, d.abs .. "/stale", PLAN)
T:arm("2 STALE another binary on PATH never outranks the resolved one", ok, why)
ok, why = run("t=$(mktemp -d " .. d.abs .. "/cp.XXXXXX) && cp $(command -v tillandsias-plan) $t/plan && echo ok:$($t/plan build-id)", nil, PLAN)
T:arm("3 COPY a copy of what command -v names is runnable", ok, why)
ok, why = run("if env -i PATH=/nonexistent /bin/sh -c 'command -v tillandsias-plan'; then echo found; else echo ok:" .. ID .. "; fi", nil, PLAN)
T:arm("4 OWNPATH CONTROL a step that sets its own PATH finds none", ok, why)
-- A runnable binary that answers another build-id: the first run's link must not outlive it.
fs.write(d.rel .. "/other-plan", '#!/bin/sh\n[ "$1" = build-id ] && { echo OTHER; exit 0; }\nexec "' .. PLAN .. '" "$@"\n')
T:must{ "chmod", "+x", d.abs .. "/other-plan" }
local other = run("[ $(tillandsias-plan build-id) = OTHER ] && echo ok:" .. ID, nil, d.abs .. "/other-plan")
ok, why = run(BARE, nil, PLAN)
T:arm("5 REFRESH a run after another binary's run reaches its own", other and ok, tostring(other) .. " " .. why)
T:finish()
