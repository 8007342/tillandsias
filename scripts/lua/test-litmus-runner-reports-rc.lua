-- @trace order:1018-5f5a, order:2386-lrg1
-- @env PATH HOME
--
-- test-litmus-runner-reports-rc.lua — every [FAIL] the litmus runner prints must carry the
-- step's exit status. Ported from test-litmus-runner-reports-rc.sh (2386-lrg1); same five arms.
--
-- 2026-09-04: a step that returned 1 was reported across three hosts as a SIGPIPE 141 because
-- the runner's [FAIL] carried no number. rc=1, 141 and 124 need three different responses.
--
--   armA (x3) BEHAVIOURAL: the three shapes, executed the runner's way (timeout --kill-after
--             around a shell), really produce 1, 141 and 124 (141 is noted, not failed, on a
--             host where the shape cannot produce it)
--   armB      STATIC: every `[FAIL]` printf in scripts/run-litmus-test.sh carries rc=%s
--   armC      CONTROL: the armB rule refuses a literal pre-fix shape (2 hits, exemption honoured)
--
-- PORT NOTE. proc.run denies `bash -c`, so each step command is a one-line script file run as
-- `timeout --kill-after=10s Ns <sh> <file>`; stdin is empty, as the .sh's </dev/null. The .sh's
-- TILLANDSIAS_TIMING_LOG export (1096-p3tn) guarded a runner this fixture never spawns; no
-- child here writes a timing record, so it is not carried.
--
-- GRAMMAR ok:litmus-runner-reports-rc:<n> arms | violation:litmus-runner-reports-rc:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-runner-reports-rc")
local SH = fixture.posix_shell()
local RUNNER = "scripts/run-litmus-test.sh"
if not fs.exists(RUNNER) then T:refuse("subject-missing", RUNNER) end
local W = T:scratch()

local seq = 0
local function step_rc(t, cmd)
    seq = seq + 1
    local f = W.rel .. "/step-" .. seq .. ".sh"
    fs.write(f, cmd .. "\n")
    local r = T:run{ "timeout", "--kill-after=10s", t .. "s", SH, W.abs .. "/step-" .. seq .. ".sh",
        stdin = "", timeout_ms = (tonumber(t) + 30) * 1000 }
    return tostring(r.code)
end

-- _rule: line numbers of [FAIL] printfs without rc=%s (exempt: 'Status: ', 'rc-exempt:').
local function rule(body)
    local hits = {}
    for i, l in ipairs(text.lines(body)) do
        if l:find("printf.*%[FAIL%]") and not l:find("rc=%s", 1, true)
            and not l:find("Status: ", 1, true) and not l:find("rc-exempt:", 1, true) then
            hits[#hits + 1] = tostring(i)
        end
    end
    return hits
end

-- armA
local a1 = step_rc("30", "exit 1")
T:arm("armA silent exit 1 -> rc=1", a1 == "1", a1)
-- A MULTI-LINE producer, deliberately (see the .sh: a single 4 MB line drains and returns 0).
local a2 = step_rc("60", "set -o pipefail; { printf 'MATCHME\\n'; head -c 4000000 /dev/zero | tr '\\0' 'x' | fold -w 80; } | /usr/bin/grep -q 'MATCHME'")
if a2 ~= "141" then
    out.line("  note: armA SIGPIPE shape produced rc=" .. a2 .. ", not 141 on this host — the 141 grammar is untested here")
end
T:arm("armA SIGPIPE shape -> rc=141 (or noted)", true, a2)
local a3 = step_rc("2", "sleep 400")
T:arm("armA timeout -> rc=124", a3 == "124", a3)

-- armB
local missing = rule(fs.read(RUNNER) or "")
T:arm("armB every [FAIL] printf in the runner carries rc=", #missing == 0,
    "[FAIL] printf without rc= at line(s): " .. table.concat(missing, " "))

-- armC: a literal pre-fix shape, independent of history (HEAD~1 was a moving ref).
local PREFIX_SHAPE = [==[
# A verbatim pre-fix shape: the two forms the runner actually used before
# 1018-5f5a, plus one exempt line that must NOT be counted as a violation.
            printf '  %b[FAIL]%b spec=%s test=%s\n' "${RED}" "${NC}" "$spec_name" "$test_name" >&2
                printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
        printf '  %b[FAIL]%b gating_points.failure matched: %s\n' "${RED}" "${NC}" "$failure" >&2   # rc-exempt: not a step exit
]==]
local n = #rule(PREFIX_SHAPE)
T:arm("armC the rule refuses both pre-fix [FAIL] forms and honours the exemption (it has teeth)", n == 2,
    n == 0 and "the rule PASSES a pre-fix shape" or ("expected exactly 2 refusals, got " .. n))

T:finish()
