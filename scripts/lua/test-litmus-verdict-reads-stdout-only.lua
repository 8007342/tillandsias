-- @trace order:1268-fx87, order:1252-fg9e, spec:ci-release
--
-- test-litmus-verdict-reads-stdout-only.lua — a litmus step's verdict is read
-- from STDOUT ONLY, and its stderr is kept and named on failure (1268-fx87).
--
-- THE DEFECT. scripts/run-litmus-test.sh ran every step with `2>&1`, so any
-- write to stderr became a candidate verdict: four arms were red only where
-- the Windows build emitted rustc warnings (`cargo build -q` silences cargo,
-- not rustc) and the Linux build did not (yolanda 2026-09-19). On Linux they
-- were green before and after, for the wrong reason: nothing wrote to stderr.
-- So the control here manufactures the contaminant instead of waiting for one.
--
-- Runs the REAL runner over a throwaway corpus (TILLANDSIAS_LITMUS_TESTS_DIR,
-- TILLANDSIAS_LITMUS_RUNTIME_DIR), one test per arm:
--   1 NEGATIVE CONTROL  stdout carries the token, stderr carries a contaminant
--                       the step's failure_pattern names -> the step PASSES
--   2 MUTATION          the same test through a copy of the runner with the
--                       merged capture restored (`2>&1`, asserted to land
--                       exactly once) -> it FAILS on the contaminant. Without
--                       this arm, 1 passes vacuously wherever nothing writes
--                       to stderr, which is every Linux host
--   3 STDOUT ONLY       the token ONLY on stderr -> FAILS (the read is not a
--                       search of both streams)
--   4 EXPLICIT MERGE    the same token, the step writing `2>&1` itself -> PASSES
--   5 NAMED ON FAILURE  a failing step's [FAIL] detail carries stderr=<path>,
--                       and that file holds what the step wrote to stderr
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-verdict-reads-stdout-only.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 300000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then
    verdict.could_not_run("litmus-verdict-stdout-fixture", "not inside a git checkout")
end
local REL = "target/plan-scratch/fx87-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/lt")
fs.mkdir(REL .. "/rt")

-- The prefix is assembled, as test-litmus-structured-assert.sh does: a literal
-- `<prefix>:<name>` in scripts/ is a pin claim the pin checker resolves.
local LIT = "litmus"
local function write_case(name, command, extra)
    local y = "test: litmus-" .. name .. "\nsize: instant\nseverity: low\nphase: pre-build\n"
        .. "critical_path:\n"
        .. "  - step: \"the only step\"\n"
        .. "    command: \"" .. command .. "\"\n"
        .. "    timeout_ms: 20000\n"
        .. extra
    fs.write(REL .. "/lt/litmus-" .. name .. ".yaml", y)
end
write_case("fx87-contam", "printf 'ok: token\\\\n'; printf 'warning: unused variable\\\\n' >&2",
    "    success_pattern: \"^ok: token$\"\n    failure_pattern: \"^warning:\"\n")
write_case("fx87-stderr-only", "printf 'ok: from-stderr\\\\n' >&2",
    "    expected_behavior: \"ok: from-stderr\"\n")
write_case("fx87-explicit", "{ printf 'ok: from-stderr\\\\n' >&2; } 2>&1",
    "    expected_behavior: \"ok: from-stderr\"\n")
write_case("fx87-named", "printf 'not the token\\\\n'; printf 'the-reason-is-here\\\\n' >&2; exit 1",
    "    expected_behavior: \"ok: never-printed\"\n")

-- The bindings are half of the seam (1252-znbn): `--test` runs a test through
-- the spec that binds it, so the throwaway corpus carries its own.
local bind = "version: '1.0'\ndescription: throwaway bindings for the 1268-fx87 fixture\nspecs:\n"
    .. "- spec_id: fx87-probe\n  status: active\n  litmus_tests:\n"
for _, nm in ipairs({ "fx87-contam", "fx87-stderr-only", "fx87-explicit", "fx87-named" }) do
    bind = bind .. "  - " .. LIT .. ":" .. nm .. "\n"
end
bind = bind .. "  coverage_ratio: 100\n"
fs.write(REL .. "/bindings.yaml", bind)

local SEAMS = {
    TILLANDSIAS_LITMUS_BINDINGS = W .. "/bindings.yaml",
    TILLANDSIAS_LITMUS_TESTS_DIR = W .. "/lt",
    TILLANDSIAS_LITMUS_RUNTIME_DIR = W .. "/rt",
}
local function litmus(runner, name) -- -> rc, combined output
    local r = run({ "bash", runner, "--test", LIT .. ":" .. name }, { cwd = ROOT, env = SEAMS })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local function short(s) return (s:gsub("%s+", " ")):sub(1, 300) end

local RUNNER = ROOT .. "/scripts/run-litmus-test.sh"

-- 1 NEGATIVE CONTROL
local rc, o = litmus(RUNNER, "fx87-contam")
check("1 a stderr contaminant does not decide a stdout verdict", rc == 0, "rc=" .. rc .. " " .. short(o))

-- 2 MUTATION: the merged capture restored, in a copy beside the original so
-- its PROJECT_ROOT and stdlib resolve the same way.
local src = fs.read("scripts/run-litmus-test.sh")
local NEEDLE = [[>"$step_capture" 2>"$step_errcap" || exit_code=$?]]
local n = 0
for _ in string.gmatch(src, (NEEDLE:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))) do n = n + 1 end
if n ~= 1 then
    check("2 the mutation lands exactly once", false, "the capture line occurs " .. n .. " times")
else
    local mutant_rel = "scripts/.fx87-mutant-runner-" .. tostring(math.random(100000, 999999)) .. ".sh"
    local s, e = string.find(src, NEEDLE, 1, true)
    fs.write(mutant_rel, src:sub(1, s - 1) .. [[>"$step_capture" 2>&1 || exit_code=$?]] .. src:sub(e + 1))
    rc, o = litmus(ROOT .. "/" .. mutant_rel, "fx87-contam")
    run({ "rm", "-f", ROOT .. "/" .. mutant_rel })
    check("2 with the merged capture restored, the contaminant IS the verdict (control is not vacuous)",
        rc == 1 and text.contains(o, "[FAIL]"), "rc=" .. rc .. " " .. short(o))
end

-- 3 STDOUT ONLY
rc, o = litmus(RUNNER, "fx87-stderr-only")
check("3 a token only on stderr does not pass (the step ran and FAILED)",
    rc == 1 and text.contains(o, "[FAIL]"), "rc=" .. rc .. " " .. short(o))

-- 4 EXPLICIT MERGE
rc, o = litmus(RUNNER, "fx87-explicit")
check("4 a step that writes 2>&1 itself still grades stderr", rc == 0, "rc=" .. rc .. " " .. short(o))

-- 5 NAMED ON FAILURE
rc, o = litmus(RUNNER, "fx87-named")
local path
for _, l in ipairs(text.lines(o)) do
    local p = l:match("stderr=(%S+)")
    if p then path = p end
end
local held = false
if path then
    local r = run({ "cat", path })
    held = r.status == "exited" and r.code == 0 and text.contains(r.stdout or "", "the-reason-is-here")
end
check("5 a failing step names its stderr log, and the log holds the stderr",
    rc == 1 and path ~= nil and held, "rc=" .. rc .. " path=" .. tostring(path) .. " held=" .. tostring(held))

run({ "rm", "-rf", W })
if failed > 0 then
    verdict.emit("refused:litmus-verdict-stdout-fixture:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:litmus-verdict-stdout-fixture:" .. passed .. " arms", 0)
