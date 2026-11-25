-- @trace order:1026-ps4n
-- A timing record survives the death of the shell that measured it, or the log says so.
-- pirria 2026-09-04: the harness killed the smoke's supervising shell, timing_emit never
-- ran, and the log was silent about a step that had run. A reaped record carries a LOWER
-- BOUND, so it is filed as <step>-supervisor-lost and never under the real step name, where
-- it would be averaged into the timings that decide what to memoise (arm 6).
-- Hermetic: a scratch stamp dir and log. Port of test-timing-supervisor-lost.sh.
local fixture = require "common.fixture"
local T = fixture.new("timing-supervisor-lost")
local d = T:scratch()
local LOG, STAMPS = d.rel .. "/timing.jsonl", d.rel .. "/pending"
local ENV = { TILLANDSIAS_TIMING_STAMP_DIR = d.abs .. "/pending", TILLANDSIAS_TIMING_LOG = d.abs .. "/timing.jsonl" }
-- Each call is one shell that sources timing-log.sh and then exits, as a killed wrapper would.
local function sh(body)
    local r = T:run{ fixture.posix_shell(), "-s", env = ENV, stdin = ". scripts/timing-log.sh || exit 97\n" .. body .. "\n" }
    if r.code ~= 0 then T:refuse("shell-failed", body .. ": " .. tostring(r.code) .. " " .. tostring(r.stderr)) end
end
local function log_text() local ok, s = pcall(fs.read, LOG); return ok and s or "" end
local function count() return select(2, log_text():gsub("[^\n]+", "")) end
local function has(step) return log_text():find('"step":"' .. step .. '"', 1, true) ~= nil end
local function stamp(step) return (pcall(fs.read, STAMPS .. "/" .. step .. ".stamp")) end

-- A live writer: begin and reap in the same shell, which is still alive at the reap.
sh("timing_begin probe-live smoke\ntiming_reap")
T:arm("1 a live writer's stamp is not reaped", count() == 0, log_text())
T:arm("2 the live stamp is left in place", stamp("probe-live"), "no stamp")
fs.write(d.rel .. "/rm.sh", 'rm -rf -- "$1"\n')
local function drop(p) T:must{ fixture.posix_shell(), d.abs .. "/rm.sh", d.abs .. "/pending" .. p } end
drop("/probe-live.stamp")

sh("timing_begin probe-lost smoke")
T:arm("3 a stamp survives the shell that wrote it", stamp("probe-lost"), "no stamp")
sh("timing_reap")
T:arm("4 a dead writer yields <step>-supervisor-lost, not silence", has("probe-lost-supervisor-lost"), log_text())
T:arm("5 the reaped stamp is cleared, so it reports once", not stamp("probe-lost"), "stamp left")
T:arm("6 no record under the real step name", not has("probe-lost"), log_text())

sh('t0="$(timing_now_ms)"\ntiming_begin probe-clean smoke\ntiming_commit probe-clean smoke "$t0" 0')
T:arm("7 commit emits the real record", has("probe-clean"), log_text())
T:arm("8 commit clears its own stamp", not stamp("probe-clean"), "stamp left")
local n = count()
sh("timing_reap")
T:arm("9 a reap after a clean commit emits nothing", count() == n, log_text())
local line = ""
for l in log_text():gmatch("[^\n]+") do if l:find('"step":"probe-clean"', 1, true) then line = l end end
T:arm("10 the clean record carries the step's exit code", line:match('"exit":([^,}]*)') == "0", line)

drop("")
fs.mkdir(STAMPS)
n = count()
sh("t=$(timing_now_ms)")
sh("timing_reap")
T:arm("11 CONTROL: a step that never stamped leaves silence", count() == n, log_text())
T:finish()
