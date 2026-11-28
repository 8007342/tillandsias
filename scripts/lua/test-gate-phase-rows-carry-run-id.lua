-- @trace order:1915-gtph, order:2301-2r4s
--
-- test-gate-phase-rows-carry-run-id.lua — one gate run's phase rows and its
-- build-check total share a run_id. Ported from the .sh (2301-2r4s).
--
-- build.sh --check flushed one `step:` row per phase (765-dfry), but nothing tied
-- those rows to the gate run that produced them, so "where did this gate's 24
-- minutes go" was a timestamp-join guess. The gate now mints one run id
-- (_gate_run_id_begin) that every timing row carries; phase rows also carry
-- their banner-to-banner wall_ms.
--
-- The REAL tracker functions are cut out of build.sh and run as a stub gate with
-- three phases. The subject is shell, so the stub is one shell file; this script
-- reads the records it wrote to a private TILLANDSIAS_TIMING_LOG.
--
-- Verdict: ok:gate-phase-rows-carry-run-id-fixture:<n> | violation:gate-phase-rows-carry-run-id:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-phase-rows-carry-run-id")
local ROOT = fixture.repo_root()
local W = T:scratch()

local FNS = { "_now_ms", "_cpu_children_now", "_phase_close", "_step", "_phase_emit_timing", "_run", "_gate_run_id_begin" }
local build = text.lines(fs.read("build.sh"))
local body, missing = {}, {}
for _, n in ipairs(FNS) do
    local on, found = false, false
    for _, l in ipairs(build) do
        if not found and l:match("^" .. n .. "%(%)%s+{") then on, found = true, true end
        if on then
            body[#body + 1] = l
            if l:sub(1, 1) == "}" then on = false end
        end
    end
    if not found then missing[#missing + 1] = n end
end
if not T:arm("1 the tracker functions are in the real build.sh", #missing == 0, "missing: " .. table.concat(missing, " ")) then
    T:finish()
end

fs.write(W.rel .. "/tracker.sh", table.concat(body, "\n") .. "\n")
fs.write(W.rel .. "/timing.jsonl", "")
fs.write(W.rel .. "/gate.sh", [==[
set -uo pipefail
cd "$(dirname "$0")" || exit 2
SCRIPT_DIR="$FIXTURE_ROOT"; FLAG_GRAPHS=true; CYAN=""; NC=""
TILLANDSIAS_HOST_ID="fixturehost"
export TILLANDSIAS_TIMING_LOG="$PWD/timing.jsonl"
unset TILLANDSIAS_TIMING_RUN_ID
_require_host_build_tools() { :; }
. "$FIXTURE_ROOT/scripts/timing-log.sh"
. ./tracker.sh
_PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0
_gate_run_id_begin
t0="$(timing_now_ms)"
_step "stub phase one";   _run true
_step "stub phase two";   _run true
_step "stub phase three"; sleep 0.2
_phase_emit_timing
timing_emit build-check check "$t0" 0
]==])
local r = T:run{ fixture.posix_shell(), W.abs .. "/gate.sh", env = { FIXTURE_ROOT = ROOT }, timeout_ms = 60000 }

local log_text = fs.read(W.rel .. "/timing.jsonl")
local phases, totals, with_id, with_wall, ids, distinct = 0, 0, 0, 0, {}, 0
for _, l in ipairs(text.lines(log_text)) do
    local phase = l:find('"step":"step:stub-phase-', 1, true) ~= nil
    if phase then phases = phases + 1 end
    if l:find('"step":"build-check"', 1, true) then totals = totals + 1 end
    local id = l:match('"run_id":"([^"]+)"')
    if id then
        with_id = with_id + 1
        if not ids[id] then ids[id] = true; distinct = distinct + 1 end
    end
    if phase and l:match('"wall_ms":%d') then with_wall = with_wall + 1 end
end
local tail = " rc=" .. tostring(r.code) .. " log=[" .. log_text:sub(1, 700) .. "] err=[" .. (r.stderr or ""):sub(-200) .. "]"
T:arm("2 three phase rows are written", phases == 3, phases .. tail)
T:arm("3 one build-check total row is written", totals == 1, totals .. tail)
T:arm("4 all four rows carry one shared run_id", with_id == 4 and distinct == 1, with_id .. "/4 carry one, " .. distinct .. " distinct" .. tail)
T:arm("5 every phase row carries wall_ms", with_wall == 3, with_wall .. tail)
T:finish({ ok = function(n) return "ok:gate-phase-rows-carry-run-id-fixture:" .. n end })
