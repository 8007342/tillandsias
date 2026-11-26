-- @trace order:1309-fhxb, order:2399-lrg3
-- @env PATH HOME
--
-- test-litmus-terminal-verdict.lua — a named skip and a declared advisory are TERMINAL
-- NON-FAILURE verdicts, and widening what counts as a non-failure did NOT widen what counts as
-- a pass: a fabricated `skip:` after a genuine failure stays RED. Ported from
-- test-litmus-terminal-verdict.sh (2399-lrg3); same sixteen checks, in its order.
--
--   recogniser   step_terminal_verdict, cut from the real runner and called through a
--                one-file shell harness (the decision IS that function)
--   runner text  the assert_exit override, the Pass Rate format, the all-skip derivation,
--                the Test Verdicts labels and their two populations
--
-- PORT NOTE. The all-skip arm inspects the runner's derivation, never a scratch litmus: a
-- fixture that spells a litmus name no corpus file declares is refused by
-- check-litmus-pin-claims, so no such name appears here either.
--
-- GRAMMAR ok:litmus-terminal-verdict:<n> arms | violation:litmus-terminal-verdict:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-terminal-verdict")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local RUNNER = fs.read("scripts/run-litmus-test.sh") or ""
if RUNNER == "" then T:refuse("no-runner", "scripts/run-litmus-test.sh is unreadable") end

local W = T:scratch()
-- The harness loads the function exactly as the .sh did (awk range from the runner) and
-- applies it to the contents of one input file. $(cat) drops trailing newlines, as the
-- .sh's $(printf ...) did.
fs.write(W.rel .. "/harness.sh", table.concat({
    'eval "$(awk \'/^step_terminal_verdict\\(\\) \\{/,/^\\}/\' "$1")"',
    'declare -f step_terminal_verdict >/dev/null || { echo "LOAD-FAILED"; exit 3; }',
    'step_terminal_verdict "$(cat "$2")"', "" }, "\n"))
local n = 0
local function v(input)
    n = n + 1
    local f = W.rel .. "/in-" .. n
    fs.write(f, input)
    local r = T:run{ SH, W.abs .. "/harness.sh", ROOT .. "/scripts/run-litmus-test.sh", W.abs .. "/in-" .. n,
        cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    local o = text.trim(r.stdout or "")
    if o == "LOAD-FAILED" then T:refuse("no-recogniser", "could not load step_terminal_verdict from the runner") end
    return o
end

T:arm("a named skip is a skip (test-spawn-failure-names-program's own output)", v("skip:no-cargo") == "skip")
T:arm("a declared advisory is an advisory (check-bash-composition-hazards' own output)",
    v("advisory:bash-hazards:pgrep-f-literal:pipelines=4:files=3") == "advisory")

-- THE LOAD-BEARING CONTROL: fabrication must not work.
for _, failure in ipairs({ "violation:something-real", "refused:preflight:x", "blocked:plan-ledger-incomplete",
    "FAIL: the assertion was false" }) do
    local got = v(failure .. "\nskip:not-my-fault\n")
    T:arm("a fabricated skip AFTER '" .. failure:match("^[^:]*") .. ":' does not rescue the step", got == "", got)
end

T:arm("a skip that is not the last line is not a verdict", v("skip:mentioned-in-passing\nok:the-real-verdict\n") == "")
T:arm("an indented/inline mention of a failure word is not a failure verdict",
    v("the script prints violation: when it refuses\nok:done\n") == "")
T:arm("NEGATIVE CONTROL: an ordinary ok: output is not a skip or advisory", v("ok:everything-fine") == "")
T:arm("NEGATIVE CONTROL: empty output is not a terminal verdict", v("") == "")

T:arm("a step declaring assert_exit that the status contradicts still FAILS, whatever it printed",
    text.contains(RUNNER, 'step_assert_exit" && "$exit_code" != "$step_assert_exit"'))
T:arm("the existing Pass Rate line keeps its exact format (seven parsers read this surface)",
    text.contains(RUNNER, "Pass Rate%b: %d%% (%d/%d executed)"))
T:arm("an all-skip test is SKIPPED, not a vacuous PASS (the derivation is wired)",
    text.contains(RUNNER, '_t_pass" -eq 0 && "$_t_skip" -gt 0'))

-- PIN THE PROPERTY, NOT THE SENTENCE: the five lines from 'Test Verdicts' on must define both
-- labels and the denominator rule (grep -A5, as the .sh read it).
local L, tv = text.lines(RUNNER), {}
for i, l in ipairs(L) do
    if text.contains(l, "Test Verdicts") then
        for j = i, math.min(#L, i + 5) do tv[#tv + 1] = L[j] end
    end
end
local tvs = table.concat(tv, " ")
local missing = {}
if not (text.contains(tvs, "skipped =") or text.contains(tvs, "skipped=")) then missing[#missing + 1] = "skipped" end
if not (text.contains(tvs, "not-run =") or text.contains(tvs, "not-run=")) then missing[#missing + 1] = "not-run" end
if not text.contains(tvs, "outside the rate") then missing[#missing + 1] = "denominator-rule" end
T:arm("both labels and the denominator rule are stated on the Test Verdicts line", #missing == 0,
    "missing: " .. table.concat(missing, " "))
T:arm("not-run is TESTS_SKIPPED minus the verdict skips — the two labels count different populations",
    text.contains(RUNNER, "TESTS_SKIPPED:-0} - ${TESTS_VERDICT_SKIPPED:-0}"))
T:arm("a test with some passing and some skipped steps stays PASSED (the rule keys on NO passing step)",
    text.contains(RUNNER, '_t_pass" -eq 0 &&'))

T:finish()
