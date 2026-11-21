-- @trace order:2150-3j97, spec:spec-traceability
-- @env PATH HOME TMPDIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-litmus-timeout-retry.lua — priority:build-speed. A litmus step killed by
-- its OWN timeout with no output is re-run once and announced as
-- flaky:<test>#<step>; an assertion red is never re-run. RC attempt 4 failed
-- only on two such kills on a loaded host. Ported from the .sh it replaces
-- (coordinator, 2026-11-21: new fixtures are Lua).
--
-- Runs the REAL runner over a throwaway corpus (TILLANDSIAS_LITMUS_BINDINGS,
-- TILLANDSIAS_LITMUS_TESTS_DIR, TILLANDSIAS_LITMUS_RUNTIME_DIR). Every arm's
-- step appends one line to a counter file per execution:
--   1  times out silently once, then passes   -> PASS, flaky: line, 2 runs
--   2  NEGATIVE CONTROL: assertion red (exit 1) -> FAIL, no flaky:, 1 run
--   3  prints output, then times out          -> FAIL, no flaky:, 1 run
--   4  times out silently twice               -> FAIL, flaky: once, 2 runs
--   5  LITMUS_TIMEOUT_RETRY=0                  -> FAIL, no flaky:, 1 run
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-timeout-retry.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 300000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then
    verdict.could_not_run("litmus-timeout-retry", "not inside a git checkout")
end
local REL = "target/plan-scratch/tr3j97-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/lt")
fs.mkdir(REL .. "/rt")
local CNT = W .. "/count"
-- The runner runs inside a SCRATCH PROJECT (a git repo holding a copy of
-- scripts/) OUTSIDE this checkout, as the .sh did. Measured: one runner start
-- with its project under this checkout's target/ took ~20 s; under /tmp, 0.5 s.
-- fs.* writes only inside the repository, so the project is made with mktemp
-- and cp through proc.run, and removed the same way at the end.
local mk = run({ "mktemp", "-d", (env.get("TMPDIR") or "/tmp") .. "/litmus-timeout-retry.XXXXXX" })
local PJ = text.trim(mk.stdout or "")
if PJ == "" then verdict.could_not_run("litmus-timeout-retry", "mktemp -d failed") end
run({ "git", "init", "-q", PJ })
run({ "cp", "-R", ROOT .. "/scripts", PJ .. "/scripts" })

-- The prefix is assembled: a literal `<prefix>:<name>` in scripts/ is a pin
-- claim the pin checker resolves.
local LIT = "litmus"
local NAME = "retry-probe"
fs.write(REL .. "/bindings.yaml", "version: '1.0'\ndescription: throwaway bindings for 2150-3j97\nspecs:\n"
    .. "- spec_id: spec-traceability\n  status: active\n  litmus_tests:\n  - " .. LIT .. ":" .. NAME
    .. "\n  coverage_ratio: 100\n")

-- The runner reads YAML through the plan binary; the scratch project has none,
-- so name the one running this script (else it falls to a slower tier).
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then
    local probe = run({ "bash", "-c", ". scripts/plan-binary-probe.sh && resolve_plan_binary" }, { cwd = ROOT })
    PLAN = text.trim(probe.stdout or "")
    if PLAN ~= "" and PLAN:sub(1, 1) ~= "/" then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
end
local SEAMS = {
    PATH = env.get("PATH"), HOME = env.get("HOME"),
    TILLANDSIAS_PLAN_BIN = PLAN,
    TILLANDSIAS_LITMUS_BINDINGS = W .. "/bindings.yaml",
    TILLANDSIAS_LITMUS_TESTS_DIR = W .. "/lt",
    TILLANDSIAS_LITMUS_RUNTIME_DIR = W .. "/rt",
}

-- probe <step command> [extra env] -> combined output, executions
local function probe(command, extra)
    fs.write(REL .. "/count", "")
    fs.write(REL .. "/lt/litmus-" .. NAME .. ".yaml",
        "test: litmus-" .. NAME .. "\nsize: instant\nseverity: low\nphase: pre-build\n"
        .. "critical_path:\n  - step: \"probe\"\n    command: \"" .. command .. "\"\n"
        .. "    timeout_ms: 2000\n    expected_behavior: \"probe-done\"\n")
    local env = {}
    for k, v in pairs(SEAMS) do env[k] = v end
    for k, v in pairs(extra or {}) do env[k] = v end
    local r = run({ "bash", PJ .. "/scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build", "--size", "instant", "--compact" },
        { cwd = PJ, env = env })
    local o = (r.stdout or "") .. (r.stderr or "")
    local body = fs.read(REL .. "/count") or ""
    local n = 0
    for _ in body:gmatch("[^\n]+") do n = n + 1 end
    return o, n
end
local function count(hay, needle)
    local n, i = 0, 1
    while true do
        local a = hay:find(needle, i, true)
        if not a then return n end
        n, i = n + 1, a + #needle
    end
end
local passed, failed = 0, 0
local function check(name, cond, o, n)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — runs=" .. n .. " " .. (o:gsub("%s+", " ")):sub(-400)) end
end
local PASS, FAIL, FLAKY = "Status: [PASS]", "Status: [FAIL]", "flaky:"
local function plain(o) return (o:gsub("\27%[[0-9;]*m", "")) end
local TICK = "echo run >> " .. CNT

local o, n = probe(TICK .. "; if [ $(grep -c . " .. CNT .. ") -ge 2 ]; then echo probe-done; else sleep 30; fi")
o = plain(o)
check("arm 1: a silent timeout is re-run once, announced flaky:<test>#<step>, and the pass stands",
    text.contains(o, PASS) and text.contains(o, "flaky:litmus-" .. NAME .. "#1 timed out") and n == 2, o, n)

o, n = probe(TICK .. "; echo wrong; exit 1"); o = plain(o)
check("arm 2 (negative control): an assertion red is never re-run and is not called flaky",
    text.contains(o, FAIL) and not text.contains(o, FLAKY) and n == 1, o, n)

o, n = probe(TICK .. "; echo partial; sleep 30"); o = plain(o)
check("arm 3: a step that printed output before its timeout is not re-run",
    text.contains(o, FAIL) and not text.contains(o, FLAKY) and n == 1, o, n)

o, n = probe(TICK .. "; sleep 30"); o = plain(o)
check("arm 4: a step that times out twice stays red after exactly one re-run",
    text.contains(o, FAIL) and count(o, FLAKY) == 1 and n == 2, o, n)

o, n = probe(TICK .. "; sleep 30", { LITMUS_TIMEOUT_RETRY = "0" }); o = plain(o)
check("arm 5: LITMUS_TIMEOUT_RETRY=0 disables the re-run",
    text.contains(o, FAIL) and not text.contains(o, FLAKY) and n == 1, o, n)

run({ "rm", "-rf", W })
run({ "find", PJ, "-delete" })
if failed > 0 then
    verdict.emit("violation:litmus-timeout-retry:" .. failed .. "-of-" .. (passed + failed) .. "-failed", 1)
end
verdict.ok("litmus-timeout-retry", passed .. "/" .. passed .. " (2150-3j97)")
