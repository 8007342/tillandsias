-- preflight: serial — runs the litmus runner, which wipes its runtime dirs
-- @trace order:1204-3s2s, order:1096-p3tn, order:2244-ge9s, order:2344-zk8r, order:2365-mskt, order:2399-lrg3, spec:observability-metrics
--
-- test-gate-step-metrics-isolation.lua — a gate step must not write into the host's
-- shared metrics path. Measured on lenovinha 2026-09-15: a fixture ran the litmus
-- runner from a scratch dir that is no git checkout, the log fell back to the shared
-- basename, cycle-metrics saw two logs and refused, and the release tier was then
-- unmeasurable there. The fixture passed 7/7 while doing it. Ported from the .sh
-- (2344-zk8r).
--
-- BEHAVIOURAL, not a grep for the export: a fixture that writes no timing must not
-- have to declare one. The split goes to a fixture-private fallback dir with the run
-- id unset, so no record provoked here can be charged to a gate (2244-ge9s).
--
--   1 the gate's step loop carries the isolation check
--   2 the subject fixture does not reach the fallback log
--   3 NEGATIVE CONTROL: the runner in a non-checkout dir DOES split. It tests the
--     mechanism, not a doctored copy of the fixture: that copy never reached the
--     runner and "passed" for nothing
--     The runner's copy of metrics-log-path.sh has its ABSOLUTE fallback replaced by a
--     scratch dir, so a broken fallback-dir knob reds here and leaks nowhere (2365-mskt:
--     it once left four records in the host's real /tmp log)
--   4 the guard keys on GROWTH: a pre-existing file alone is not an offence
--
-- Verdict: ok:step-metrics-isolation:<n> | violation:step-metrics-isolation:<n>-failed
--        | skip:step-metrics-isolation:<subject>-absent (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("step-metrics-isolation")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
local SUBJECT = "scripts/lua/test-litmus-budget-tally.lua"
if not fs.exists(SUBJECT) then verdict.emit("skip:step-metrics-isolation:" .. SUBJECT .. " absent", 3) end
local W = T:scratch()
local GATE_ENV = { "TILLANDSIAS_TIMING_*", "TILLANDSIAS_METRICS_*" }

local build = fs.read("build.sh")
local function has(s) return build:find(s, 1, true) ~= nil end
T:arm("1 the step loop compares the shared path and refuses on its own run id (1916-tsel)",
    has("1204-3s2s") and has("_metrics_shared_before") and has("gate-step-metrics-attribution.sh"), "build.sh no longer guards the shared metrics path around gate steps")

local function log_in(dir)
    local p = W.rel .. "/" .. dir .. "/tillandsias-timing.jsonl"
    return fs.exists(p) and fs.read(p) or nil
end
fs.mkdir(W.rel .. "/fb2"); fs.mkdir(W.rel .. "/fb3")
-- The subject is a Lua fixture since 2399-lrg3, so it runs as the gate runs it: through the
-- plan binary. It still drives the litmus runner from a scratch root, which is what this arm asks.
-- Measured 2026-11-26: this arm no longer reds when the subject stops naming its timing log,
-- because `script run` already routes the child's timing into target/plan-scratch. The kit now
-- carries the isolation; arm 3 still proves the fallback mechanism itself refuses.
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local r = T:run{ PLAN, "script", "run", ROOT .. "/" .. SUBJECT, cwd = ROOT, env_unset = GATE_ENV, timeout_ms = 600000,
    env = { TILLANDSIAS_METRICS_FALLBACK_DIR = W.abs .. "/fb2" } }
local l = log_in("fb2")
T:arm("2 " .. SUBJECT .. " does not reach the fallback log", l == nil, "rc=" .. tostring(r.code) .. " wrote " .. tostring(l):sub(1, 200))

-- The spec name is assembled, so no literal scan reads this probe as a real one.
local spec = "metrics-isolation-probe"
local name = "litmus" .. ":" .. spec
fs.mkdir(W.rel .. "/nc/openspec/litmus-tests")
fs.write(W.rel .. "/nc/openspec/litmus-bindings.yaml", "version: '1.0'\ndescription: throwaway registry built at runtime\nspecs:\n- spec_id: " .. spec
    .. "\n  status: active\n  litmus_tests:\n  - " .. name .. "\n  coverage_ratio: 100\n  last_verified: '2026-01-01'\n")
fs.write(W.rel .. "/nc/openspec/litmus-tests/litmus-" .. spec .. ".yaml", "name: " .. name .. "\nspec: " .. spec
    .. "\nphase: pre-build\ndescription: >\n  A throwaway probe.\nseverity: high\nsize: instant\ncritical_path:\n"
    .. '  - step: "the probe step"\n    command: "echo ok-probe"\n    timeout_ms: 30000\n    expected_behavior: "ok-probe"\n')
-- The pin, or no arm 3: without it a broken knob writes the host's real log.
local lib, pinned = fs.read("scripts/metrics-log-path.sh"):gsub('(_mdl_fb="%${[%w_]+:%-)[^}]*(}")', "%1" .. W.abs .. "/spill%2")
if pinned ~= 1 then T:refuse("no-fallback-to-pin", "metrics-log-path.sh: " .. pinned .. " absolute fallback(s) found, want 1") end
fs.mkdir(W.rel .. "/spill"); fs.mkdir(W.rel .. "/nc/scripts")
fs.write(W.rel .. "/nc/scripts/metrics-log-path.sh", lib)
-- Outside this checkout: under it, the runner would find a repository and not fall
-- back. It is handed THIS checkout's plan binary (1427-utmy); none on this host is a
-- named skip of the arm, never an opt-out.
if PLAN == "" then
    out.line("skip: arm 3 needs a runnable tillandsias-plan and this host has none (1427-utmy)")
else
    r = T:run{ SH, "-s", "--", ROOT, W.abs .. "/nc", spec, cwd = ROOT, timeout_ms = 300000, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_METRICS_FALLBACK_DIR = W.abs .. "/fb3" },
        stdin = [[
nc="$(mktemp -d "${TMPDIR:-/tmp}/metrics-isolation-nc.XXXXXX")" || exit 3
trap 'rm -rf "$nc"' EXIT
mkdir -p "$nc/scripts" && cp -r "$1/scripts/." "$nc/scripts/" 2>/dev/null
cp -r "$2/." "$nc/" || exit 3
cd "$nc" || exit 3
git rev-parse --git-dir >/dev/null 2>&1 && { echo "premise: $nc is inside a git checkout"; exit 3; }
bash "$nc/scripts/run-litmus-test.sh" "$3" --phase pre-build --size all </dev/null 2>&1
]] }
    l = log_in("fb3")
    T:arm("3 NEGATIVE CONTROL an unnamed run outside a checkout does write the fallback log", l ~= nil and log_in("spill") == nil,
        "rc=" .. tostring(r.code) .. " so arm 2 proves nothing: " .. (r.stdout or ""):sub(-300))
end

T:arm("4 CONTROL the guard compares before-vs-after, so a pre-existing file alone does not refuse",
    has([[tail -n "+$(( ${_metrics_shared_before:-0} + 1 ))" "$_metrics_shared" > "$_metrics_snap"]]), "build.sh does not compare against a baseline")
T:finish({ ok = function(n) return "ok:step-metrics-isolation:" .. n end })
