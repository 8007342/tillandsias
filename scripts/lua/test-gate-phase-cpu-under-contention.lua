-- @env PATH HOME
-- @trace order:839-veey
--
-- test-gate-phase-cpu-under-contention.lua — build.sh's phase report carries each phase's CPU
-- time beside its wall clock, and marks a phase whose wall clock is mostly waiting, so a number
-- inflated by contention is never read as the step's cost.
--
-- WHY (839-veey). MEASURED on macOS 2026-08-20: under a concurrent gate the report put 918 s on
-- scripts/check-plan-binary-probe-usage.sh (2.96 s alone, 310x) and 920 s on the pre-commit
-- hook (3.06 s of CPU in 15 m 20 s of wall: 0% CPU). Those numbers produced a wrong diagnosis
-- (835-kjuv). A wall clock alone cannot tell computing from waiting; CPU time can.
--
-- The tracker functions are cut from build.sh and run in bash over three phases:
--   1 the functions are found
--   2 WAITING   a phase that sleeps reports ~0 s of CPU and is marked as waiting
--   3 BUSY      a CPU-bound phase reports CPU close to its wall clock and is not marked
--   4 CONTENDED a CPU-bound phase pinned to one core beside two planted CPU hogs on the same
--               core reports CPU well under its wall clock and is marked (the planted
--               concurrent load); skipped where taskset is absent
--   5 the timing emit still writes one step: record per phase (the new column breaks no reader)
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-phase-cpu-under-contention.lua
-- Verdict: ok:gate-phase-cpu-under-contention:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("gate-phase-cpu-under-contention")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local src, got, lost = "\n" .. fs.read("build.sh"):gsub("\r", ""), {}, {}
for _, f in ipairs{ "_now_ms", "_cpu_children_now", "_phase_close", "_step", "_phase_emit_timing", "_run", "_phase_report" } do
    local body = src:match("\n(" .. f .. "%(%)%s*{\n.-\n})\n")
    if body then got[#got + 1] = body else lost[#lost + 1] = f end
end
T:arm("1 the tracker functions are cut from build.sh", #lost == 0, table.concat(lost, " "))
-- A missing function is stubbed so the report still runs: on a pre-fix build.sh the arms below
-- then fail on what the report SAYS, not on a missing name.
for _, f in ipairs(lost) do got[#got + 1] = f .. "() { _CPU_NOW=-1; }" end
local d = T:scratch()
fs.write(d.rel .. "/tracker.sh", table.concat(got, "\n") .. "\n")
local PRE = [==[
set -uo pipefail
SCRIPT_DIR="$1"; W="$2"; FLAG_GRAPHS=true; CYAN=""; NC=""; TILLANDSIAS_HOST_ID=fixturehost
_require_host_build_tools() { :; }
_info() { printf 'info: %s\n' "$*" >&2; }
. "$W/tracker.sh"
_PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0; _PHASE_CPU_FILE="$W/cpu"
busy() { local i=0; while [ "$i" -lt "$1" ]; do i=$((i + 1)); done; }
export -f busy
]==]
local function sh(body)
    return T:run{ SH, "-s", "--", ROOT, d.abs, cwd = d.abs, stdin = PRE .. body, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 180000 }
end
local has_taskset = fixture.which("taskset") ~= nil
local body = [==[
_step "waiting phase"; _run sleep 3
_step "busy phase"; _run bash -c 'busy 1500000'
]==]
if has_taskset then
    body = body .. [==[
taskset -c 0 bash -c 'busy 40000000' & h1=$!
taskset -c 0 bash -c 'busy 40000000' & h2=$!
_step "contended phase"; _run taskset -c 0 bash -c 'busy 1500000'
_phase_close   # before the hogs are reaped: wait would add their CPU to the open phase
kill "$h1" "$h2" 2>/dev/null; wait "$h1" "$h2" 2>/dev/null
]==]
end
body = body .. [==[
TILLANDSIAS_GATE_PROFILE=1 _phase_report
TILLANDSIAS_TIMING_LOG="$W/t.jsonl" _phase_emit_timing
]==]
local r = sh(body)
local out = (r.stdout or "") .. (r.stderr or "")
local function line(name) return ("\n" .. out):match("\n([^\n]*" .. name:gsub("%-", "%%-") .. "[^\n]*)") or "" end
local function cpu(l) return tonumber(l:match("cpu (%d+%.%d)s")) end
local function wall(l) return tonumber(l:match("^%s*(%d+%.%d)s")) end
local lw, lb, lc = line("waiting phase"), line("busy phase"), line("contended phase")
T:arm("2 WAITING a phase that sleeps reports ~0 s of CPU", cpu(lw) ~= nil and cpu(lw) < 0.5 and (wall(lw) or 0) >= 2.5, lw ~= "" and lw or out:sub(1, 400))
T:arm("2 WAITING and is marked as waiting", text.contains(lw, "waited"), lw)
T:arm("3 BUSY a CPU-bound phase reports CPU close to its wall clock", cpu(lb) ~= nil and wall(lb) ~= nil and cpu(lb) >= 0.6 * wall(lb), lb)
T:arm("3 BUSY and is not marked", lb ~= "" and not text.contains(lb, "waited"), lb)
if has_taskset then
    T:arm("4 CONTENDED a pinned phase beside two hogs reports CPU well under its wall clock", cpu(lc) ~= nil and wall(lc) ~= nil and cpu(lc) < 0.6 * wall(lc), lc)
    T:arm("4 CONTENDED and is marked", text.contains(lc, "waited"), lc)
else
    out.line("skip: 4 no taskset on this host: the planted concurrent load cannot be pinned")
end
local n = 0
for l in (fs.exists(d.rel .. "/t.jsonl") and fs.read(d.rel .. "/t.jsonl") or ""):gmatch("[^\n]+") do
    if text.contains(l, '"step":"step:') then n = n + 1 end
end
T:arm("5 the timing emit still writes one step: record per phase", n == (has_taskset and 3 or 2), n .. " records")
T:finish()
