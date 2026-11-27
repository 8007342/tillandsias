-- @trace order:1076-kft9, order:2348-psb6
-- @env PATH HOME
--
-- test-sigpipe-verdict-measured.lua — the self-test for the measuring check
-- (scripts/lib-sigpipe-verdict.sh). Ported from test-sigpipe-verdict-measured.sh
-- (2348-psb6); same five arms. The library is bash, so each arm sources it in a bash
-- child fed on stdin; the verdict is read here, never piped into one.
--
-- THE CONDITION is whether the producer still has bytes to write when the consumer
-- exits: `grep -q` leaves at its first match. Two routes reach it: a slow producer
-- (drvfs 10/10, ext4 0/10, and a per-line read loop on ext4 10/10 — the causal
-- control), and an early match in a fast producer with output left
-- (`seq 1 20000 | grep -qxF 1` is 141). A known-bad calibration case therefore
-- cannot be a live file; arm 1 keeps the deliberately slowed producer.
--
--   1 KNOWN-BAD  a slowed producer whose consumer matches is sigpipe-decided
--   2 no 141 observed is unmeasured:not-observed, NEVER measured-clean. The corpus is
--     under PIPE_BUF so it goes in one write: structurally clean, not empirically
--     (a 58 KB corpus was intermittently red on a Fedora host, 2 of 6 runs)
--   3 no match today is unmeasured:no-match-today, not safety
--   4 a runtime-sized producer is unmeasured:...runtime-property
--   5 TEETH the broken `eval "a | b"` form yields a 1-element PIPESTATUS, so a naive
--     check passes arms 1-4 while measuring nothing
--
-- Scratch is INSIDE the checkout (target/plan-scratch) on purpose: it inherits the
-- checkout's filesystem, which is a variable that decides the answer.
--
-- GRAMMAR ok:sigpipe-verdict-measured:5 arms | violation:sigpipe-verdict-measured:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("sigpipe-verdict-measured")
local ROOT = fixture.repo_root()
local CHECK = "scripts/lib-sigpipe-verdict.sh"
if not pcall(fs.read, CHECK) then T:refuse("check-missing", "the check is missing: " .. CHECK) end
local W = T:scratch()

local big, small = {}, {}
for i = 1, 1200 do big[#big + 1] = i == 300 and "NEEDLE_HERE marker line" or "filler filler filler filler filler filler filler filler filler" end
for i = 1, 20 do small[#small + 1] = i == 5 and "NEEDLE_HERE marker line" or "filler" end
fs.write(W.rel .. "/corpus.txt", table.concat(big, "\n") .. "\n")
fs.write(W.rel .. "/small.txt", table.concat(small, "\n") .. "\n")
local CORPUS, SMALL = W.abs .. "/corpus.txt", W.abs .. "/small.txt"

-- bash <script>: the library sourced, then the script; stdout trimmed.
local function bash(script)
    local r = T:run{ fixture.posix_shell(), "-s", cwd = ROOT, timeout_ms = 120000,
        stdin = 'set -uo pipefail\n. "' .. ROOT .. '/' .. CHECK .. '"\n' .. script .. '\n' }
    return text.trim(r.stdout or ""), r
end

local v = bash("REPS=3 measure_pipeline fx 1 \"SLOW_READ " .. CORPUS .. "\" \"-q 'NEEDLE_HERE'\"")
T:arm("1 a slowed producer whose consumer MATCHES is sigpipe-decided", v:match("^sigpipe%-decided:") ~= nil, v)

v = bash("REPS=3 measure_pipeline fx 2 \"cat " .. SMALL .. "\" \"-q 'NEEDLE_HERE'\"")
T:arm("2 no 141 observed reads unmeasured:not-observed, NOT clean",
    v:match("^unmeasured:") ~= nil and text.contains(v, "not-observed") and v:match("^measured%-clean:") == nil, v)

v = bash("REPS=3 measure_pipeline fx 3 \"cat " .. CORPUS .. "\" \"-q 'ABSENT_TOKEN_XYZ'\"")
T:arm("3 a consumer with nothing to match is unmeasured:no-match-today", v:match("^unmeasured:") ~= nil and text.contains(v, "no-match-today"), v)

v = bash([[verdict fx 4 "printf '%s' \"\$out\"" "-q 'x'"]])
T:arm("4 a runtime-sized producer is unmeasured", v:match("^unmeasured:") ~= nil and text.contains(v, "runtime-property"), v)

v = bash('eval "SLOW_READ ' .. CORPUS .. [[ | grep -q 'NEEDLE_HERE'" >/dev/null 2>&1; echo "${#PIPESTATUS[@]}"]])
T:arm("5 CONTROL an evaled pipeline yields a 1-element PIPESTATUS, so the naive form measures nothing", v == "1", "PIPESTATUS elements: " .. v)

T:finish()
