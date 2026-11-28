-- @trace order:1242-4x53, spec:methodology-accountability
-- A timing record says whether a failure REPRODUCED, when its caller knows. On 2026-09-17 both
-- failures in a red release tier passed on re-run, and the log had no field to say so.
-- Absent means "not re-run" or "written before the field existed", NEVER "did not reproduce": a
-- value outside yes|no is dropped, since coercing it to "no" would manufacture the very
-- non-determinism evidence the field measures. Arms 8-10 pin the batch emitter's status and
-- failed_step the same way. Hermetic: every record goes to a scratch log.
-- Port of test-timing-record-carries-reproduced.sh. The verdict line is the one its litmus matches.
local fixture = require "common.fixture"
local T = fixture.new("timing-record-reproduced")
local d = T:scratch()
local SH = fixture.posix_shell()
local function log(name) return { TILLANDSIAS_TIMING_LOG = d.abs .. "/" .. name } end
-- The log's raw text, its last line, and that line parsed (nil when it is not JSON).
local function last(name)
    local ok, s = pcall(fs.read, d.rel .. "/" .. name)
    s = ok and s or ""
    local line = ""
    for l in s:gmatch("[^\n]+") do line = l end
    local parsed, rec = pcall(json.parse, line)
    return s, line, parsed and type(rec) == "table" and rec or nil
end
-- "ABSENT" only when a valid record carries no such key; a missing or broken record is neither.
local function field(name)
    local _, _, rec = last(name)
    if rec == nil then return "NO-RECORD" end
    if rec.reproduced == nil then return "ABSENT" end
    return rec.reproduced
end
local function emit(name, token)
    T:run{ SH, "scripts/cycle-metrics.sh", "--emit-timing", "step=arm", "phase=test", "duration_ms=5", "exit=1", token,
        env = log(name) }
    return field(name)
end
local function arm(label, name, got, want) T:arm(label, got == want, got .. ": " .. (last(name))) end

arm("1 reproduced=yes is recorded", "a1", emit("a1", "reproduced=yes"), "yes")
arm("2 reproduced=no is recorded", "a2", emit("a2", "reproduced=no"), "no")
arm("3 no token writes no reproduced key", "a3", emit("a3"), "ABSENT")
arm("4 an invalid value writes no key and the row stays valid JSON", "a4", emit("a4", 'reproduced=maybe"x'), "ABSENT")

-- Positional readers: the leading keys, in file order.
local keys = {}
for k in select(2, last("a1")):gmatch('"([%w_]+)":') do if #keys < 6 then keys[#keys + 1] = k end end
arm("5 the leading field order is unchanged", "a1", table.concat(keys, ","), "ts,host,step,phase,duration_ms,exit")

-- The shell API its callers use.
local function timing_emit(name, tail)
    T:must{ SH, "-s", env = log(name), stdin = ". scripts/timing-log.sh || exit 97\n"
        .. 'now="$(timing_now_ms)"\ntiming_emit ' .. name .. ' test "$((now - 50))" 1' .. tail .. "\n" }
    return field(name)
end
arm("6 timing_emit forwards its fifth argument", "a6", timing_emit("a6", " yes"), "yes")
arm("7 a four-argument timing_emit writes no reproduced key", "a7", timing_emit("a7", ""), "ABSENT")

-- The batch emitter: columns 6 and 7 are status and failed_step.
T:run{ SH, "scripts/cycle-metrics.sh", "--emit-timing-batch", env = log("b"),
    stdin = "litmus:Ta\tp\t120\t1\th\tfail\t3\nlitmus:Tb\tp\t80\t0\th\tpass\t\nlitmus:Tc\tp\t5\t0\th\tbogus\t2x\n" }
local got = {}
for l in (last("b")):gmatch("[^\n]+") do
    local parsed, rec = pcall(json.parse, l)
    if parsed and type(rec) == "table" and rec.step then
        got[rec.step] = tostring(rec.status or "ABSENT") .. "," .. tostring(rec.failed_step or "ABSENT")
    end
end
local function batch(label, step, want) arm(label, "b", got[step] or "NO-RECORD", want) end
batch("8 a failed test records status=fail and the step it died on", "litmus:Ta", "fail,3")
batch("9 a passing test records status=pass and no failed_step", "litmus:Tb", "pass,ABSENT")
batch("10 an out-of-domain status and step write no keys", "litmus:Tc", "ABSENT,ABSENT")
T:finish{ ok = function(n) return "ok:timing-record-reproduced:" .. n .. "/10" end }
