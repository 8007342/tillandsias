-- @trace order:1419-zydw, order:2294-y3iu
--
-- test-litmus-no-plan-binary.lua — the litmus runner refuses ONCE, by name, when
-- no RUNNABLE tillandsias-plan resolves, instead of letting plan-backed steps
-- degrade into several unrelated-looking reds. Ported from the .sh (2294-y3iu).
--
-- MEASURED 2026-09-26 (darwin, fresh linked worktree): four reds with four
-- surfaces, all green once a binary was supplied. And a broken
-- TILLANDSIAS_PLAN_BIN made the runner exit with the stub's own rc and NO output.
--
-- The refusal precedes selection, so every arm names a spec that matches
-- nothing. The admitted arms require what the runner then says ("no litmus tests
-- matched"); the .sh only required that it did not refuse, so a runner that died
-- at start passed four of its six arms.
--
--   1 NONE       no binary: one named refusal, rc 2
--   2 UNRUNNABLE a binary that exists but does not run: refused by its own name
--   3 OPT-OUT    TILLANDSIAS_LITMUS_ALLOW_NO_PLAN_BIN=1 reaches selection
--   4 PARSE      --parse-only needs no binary: it names the file parseable, rc 0
--   5 LIST       --list needs no binary: it lists suites, rc 0
--   6 ADMITTED   a runnable binary reaches selection
--
-- Verdict: ok:litmus-no-plan-binary:<n> | violation:litmus-no-plan-binary:<n>

local fixture = require "common.fixture"
local T = fixture.new("litmus-no-plan-binary")
local ROOT = fixture.repo_root()
local W = T:scratch()
local SPEC = "no-such-spec-1419"
local LITMUS = "openspec/litmus-tests/litmus-litmus-no-plan-binary-refusal.yaml"

-- rc, everything said (colour stripped), the first STDOUT line that is not a warn:
local function run(args, e)
    local argv = { fixture.posix_shell(), "scripts/run-litmus-test.sh" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd = ROOT; argv.env = e; argv.timeout_ms = 60000
    local r = T:run(argv)
    local o = ((r.stdout or "") .. "\n"):gsub("\27%[[0-9;]*m", "")
    local first = ""
    for _, l in ipairs(text.lines(o)) do
        if text.trim(l) ~= "" and l:sub(1, 5) ~= "warn:" then first = l; break end
    end
    return r.code, o .. ((r.stderr or ""):gsub("\27%[[0-9;]*m", "")), first
end
local SELECT = { SPEC, "--phase", "pre-build", "--size", "instant", "--compact" }
local ABSENT = { TILLANDSIAS_PLAN_BIN = W.abs .. "/absent", CARGO_TARGET_DIR = W.abs .. "/no-target" }
local function matched_nothing(o) return o:lower():find("no litmus tests matched", 1, true) ~= nil end
local function got(rc, first, o) return "rc=" .. tostring(rc) .. " first=[" .. first .. "] tail=[" .. o:sub(-160) .. "]" end

local rc, o, first = run(SELECT, ABSENT)
T:arm("1 NONE no plan binary is one named refusal, rc 2", rc == 2 and first == "blocked:litmus-no-plan-binary" and not matched_nothing(o), got(rc, first, o))

fs.write(W.rel .. "/broken", "#!/bin/sh\nexit 3\n")
T:must{ "chmod", "+x", W.abs .. "/broken" }
rc, o, first = run(SELECT, { TILLANDSIAS_PLAN_BIN = W.abs .. "/broken" })
T:arm("2 UNRUNNABLE a binary that does not run is refused by its own name, not a silent exit",
    rc == 2 and first == "blocked:litmus-plan-binary-unrunnable:" .. W.abs .. "/broken", got(rc, first, o))

rc, o, first = run(SELECT, { TILLANDSIAS_PLAN_BIN = ABSENT.TILLANDSIAS_PLAN_BIN, CARGO_TARGET_DIR = ABSENT.CARGO_TARGET_DIR,
    TILLANDSIAS_LITMUS_ALLOW_NO_PLAN_BIN = "1" })
T:arm("3 OPT-OUT the opt-out reaches selection", matched_nothing(o) and not o:find("blocked:litmus-", 1, true), got(rc, first, o))

rc, o, first = run({ "--parse-only", LITMUS }, ABSENT)
T:arm("4 PARSE --parse-only runs without a plan binary", rc == 0 and o:find("ok:litmus-parseable:" .. LITMUS, 1, true) ~= nil, got(rc, first, o))
rc, o, first = run({ "--list" }, ABSENT)
T:arm("5 LIST --list runs without a plan binary", rc == 0 and o:find("Available Litmus Test Suites", 1, true) ~= nil, got(rc, first, o))

local real = fixture.plan_binary()
if real == "" then
    out.line("not-judged: 6 ADMITTED no runnable tillandsias-plan on this host")
else
    rc, o, first = run(SELECT, { TILLANDSIAS_PLAN_BIN = real })
    T:arm("6 ADMITTED a runnable binary reaches selection", matched_nothing(o) and not o:find("blocked:litmus-", 1, true), got(rc, first, o))
end
T:finish()
