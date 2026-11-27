-- @trace order:1252-znbn, order:2386-lrg1
-- @env PATH HOME
--
-- test-litmus-structured-assert.lua — a step declaring `assert_*` is adjudicated by those
-- fields ONLY, so rewording the prose beside them cannot change the verdict. Ported from
-- test-litmus-structured-assert.sh (2386-lrg1); same ten arms.
--
-- THE DEFECT. behavior_matches_output interprets English in bash `case` arms: `*"succeeds"*`
-- honours the exit code, the fallback is a LITERAL grep (868-p8xi: `(a|b)` never matches).
--
-- ARM 1 USES AN EQUALIZED CONTROL: the pre-fix runner is HEAD's (`git show`, read-only) with
-- only the two discovery overrides, its own-path lookups pinned to this checkout's scripts/
-- (1611-imnj: the copy lives in scratch, never beside scripts/), and the 2309-fa7q exit rule cut.
--
--   0  the pre-fix control reaches the throwaway suite (discovery equalized)
--   1  PRE-FIX the same command yields two verdicts from prose alone
--   2  POST-FIX assert_exit:3 passes under three prose variants
--   3  a WRONG assert_exit fails the step
--   4  assert_output_matches treats (a|b) as a regex
--   5  assert_output_matches fails when no branch matches
--   6b assert_output_nonempty passes when the step prints
--   6c assert_output_nonempty FAILS on a silent step
--   6  matching text at exit 3 fails without a declared exit (2309-fa7q)
--   6d the same step at exit 0 adjudicates by its text
--
-- ENV. As the .sh: the runner gets the ambient env plus TILLANDSIAS_LITMUS_BINDINGS and
-- TILLANDSIAS_LITMUS_TESTS_DIR, from cwd = the repo root. Nothing re-enters build.sh.
--
-- GRAMMAR ok:litmus-structured-assert:<n> arms | violation:litmus-structured-assert:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-structured-assert")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local RUNNER = ROOT .. "/scripts/run-litmus-test.sh"
if not fs.exists("scripts/run-litmus-test.sh") then T:refuse("subject-missing", RUNNER) end
local W = T:scratch()
local PREFIX_RUNNER = W.abs .. "/znbn-prefix-runner.sh"
fs.mkdir(W.rel .. "/lt")

-- The pin token is ASSEMBLED (check-litmus-pin-claims.sh scans for `<prefix>:<name>`).
local LIT = "litmus"
fs.write(W.rel .. "/bindings.yaml", "version: '1.0'\n"
    .. "description: throwaway bindings for the 1252-znbn fixture\n"
    .. "specs:\n- spec_id: znbn-probe\n  status: active\n  litmus_tests:\n"
    .. "  - " .. LIT .. ":znbn-probe\n  coverage_ratio: 100\n")

local CASE = W.rel .. "/lt/litmus-znbn-probe.yaml"
local function write_case(prose, extra)
    local s = "test: litmus-znbn-probe\nsize: instant\nseverity: low\nphase: pre-build\n"
        .. "critical_path:\n"
        .. '  - step: "one step; only the prose and the assertions vary"\n'
        .. '    command: "echo hello; exit 3"\n'
        .. "    timeout_ms: 5000\n"
        .. '    expected_behavior: "' .. prose .. '"\n'
    if extra and extra ~= "" then s = s .. "    " .. extra .. "\n" end
    fs.write(CASE, s)
end
-- Plain (non-pattern) replace of the first occurrence; count = how many to replace (nil = all).
local function replace(s, old, new, count)
    local acc, i, n = {}, 1, 0
    while true do
        local a, b = s:find(old, i, true)
        if not a or (count and n >= count) then break end
        acc[#acc + 1] = s:sub(i, a - 1) .. new; i = b + 1; n = n + 1
    end
    acc[#acc + 1] = s:sub(i)
    return table.concat(acc)
end
local function edit_case(old, new) fs.write(CASE, replace(fs.read(CASE) or "", old, new, 1)) end
local function run_with(runner)
    local r = T:run{ SH, runner, "znbn-probe", cwd = ROOT, timeout_ms = 120000,
        env = { TILLANDSIAS_LITMUS_BINDINGS = W.abs .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = W.abs .. "/lt" } }
    return r.code
end

-- The pre-fix control (the .sh's two sed passes, line-anchored where its sed was).
local head = T:run{ "git", "-C", ROOT, "show", "HEAD:scripts/run-litmus-test.sh" }
local pre = ""
if head.code == 0 then
    local lines = {}
    for _, l in ipairs(text.lines(head.stdout or "")) do
        if l:sub(1, #'readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"') == 'readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"' then
            l = replace(l, 'readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"',
                'readonly LITMUS_BINDINGS="${TILLANDSIAS_LITMUS_BINDINGS:-${PROJECT_ROOT}/openspec/litmus-bindings.yaml}"', 1)
        elseif l:sub(1, #'readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"') == 'readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"' then
            l = replace(l, 'readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"',
                'readonly LITMUS_TESTS_DIR="${TILLANDSIAS_LITMUS_TESTS_DIR:-${PROJECT_ROOT}/openspec/litmus-tests}"', 1)
        end
        l = replace(l, '$(dirname "${BASH_SOURCE[0]}")', ROOT .. "/scripts")
        l = replace(l, 'elif [[ -n "$step_expected" && "$exit_code" -ne 0 ]]; then', "elif false; then # no-exit-rule", 1)
        lines[#lines + 1] = l
    end
    pre = table.concat(lines, "\n") .. "\n"
end
fs.write(W.rel .. "/znbn-prefix-runner.sh", pre)

-- ARM 0, asserted BEFORE any verdict is read from the control.
local A0 = "0 pre-fix control reaches the throwaway suite (discovery equalized)"
local no_exit_rule = 0
for _, l in ipairs(text.lines(pre)) do if l:sub(-#"# no-exit-rule") == "# no-exit-rule" then no_exit_rule = no_exit_rule + 1 end end
local _, overrides = pre:gsub("TILLANDSIAS_LITMUS_", "")
if text.contains(pre, "BASH_SOURCE") then
    T:arm(A0, false, "the control still resolves a path from its own location (BASH_SOURCE); pin the new lookup")
elseif no_exit_rule ~= 1 then
    T:arm(A0, false, "the control still carries the 2309-fa7q exit rule (its line moved); cut it again")
elseif pre ~= "" and overrides >= 2 then
    write_case("hello", "")
    local rc = run_with(PREFIX_RUNNER)
    T:arm(A0, rc == 0, "control did not PASS a case it should (rc=" .. tostring(rc) .. ") — every later arm is void")
else
    T:arm(A0, false, "could not build an equalized pre-fix control; arms 1-2 prove nothing")
end

-- ARM 1
write_case("the command succeeds", ""); local rc_succeeds = run_with(PREFIX_RUNNER)
write_case("hello", "");                local rc_literal = run_with(PREFIX_RUNNER)
T:arm("1 PRE-FIX the same command yields two verdicts from prose alone (succeeds->FAIL, literal->PASS)",
    rc_succeeds ~= 0 and rc_literal == 0, "succeeds=" .. tostring(rc_succeeds) .. " literal=" .. tostring(rc_literal))

-- ARM 2
local moved = {}
for _, prose in ipairs{ "the command succeeds", "hello", "prints multiple things" } do
    write_case(prose, "assert_exit: 3")
    if run_with(RUNNER) ~= 0 then moved[#moved + 1] = prose end
end
T:arm("2 POST-FIX assert_exit:3 passes under all three prose variants — the sentence is inert", #moved == 0,
    "moved under: " .. table.concat(moved, " | "))

-- ARM 3
write_case("irrelevant", "assert_exit: 0")
T:arm("3 a WRONG assert_exit fails the step", run_with(RUNNER) ~= 0, "assert_exit: 0 passed against exit 3")

-- ARM 4 / 5
write_case("irrelevant", 'assert_output_matches: "(hello|goodbye)"')
T:arm("4 assert_output_matches treats (a|b) as a regex", run_with(RUNNER) == 0, "an alternation that should match did not")
write_case("irrelevant", 'assert_output_matches: "(nope|never)"')
T:arm("5 assert_output_matches fails when no branch matches", run_with(RUNNER) ~= 0, "a non-matching alternation passed")

-- ARM 6b / 6c: nonempty is judged independently of exit status.
write_case("irrelevant", "assert_output_nonempty: true")
edit_case('command: "echo hello; exit 3"', 'command: "echo hello"')
T:arm("6b assert_output_nonempty passes when the step prints", run_with(RUNNER) == 0, "a printing step failed")
edit_case('command: "echo hello"', 'command: "true"')
T:arm("6c assert_output_nonempty FAILS on a silent step (rc=0 but no output)", run_with(RUNNER) ~= 0, "a silent step passed")

-- ARM 6 / 6d (2309-fa7q)
write_case("hello", "")
T:arm("6 matching text at exit 3 fails without a declared exit", run_with(RUNNER) ~= 0, "matching text at exit 3 passed")
edit_case('command: "echo hello; exit 3"', 'command: "echo hello"')
T:arm("6d the same step at exit 0 adjudicates by its text", run_with(RUNNER) == 0, "matching text at exit 0 failed")

T:finish()
