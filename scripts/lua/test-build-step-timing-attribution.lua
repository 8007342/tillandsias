-- @env PATH HOME
-- @trace order:785-ibu9, order:2372-snfs
--
-- test-build-step-timing-attribution.lua — a build.sh timing record measures the step's OWN work,
-- not the span to the next banner. Ported from the .sh of the same name (2372-snfs). It runs the
-- real tracker functions, cut from build.sh, over three short steps.
--
--   1 all five functions are found      2 a fast step excludes the unnamed second after it
--   3 a slow step reports its own       4 both carry phase=build   5 a step with no _run is
--   build-span, with its wall clock     6 three step: records      7 _run keeps its exit code
--   8 a stuck clock degrades to 0 and never fails the emit
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-step-timing-attribution.lua
-- Verdict: ok:build-step-timing-attribution:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("build-step-timing-attribution")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local src, got, lost = "\n" .. fs.read("build.sh"):gsub("\r", ""), {}, {}
for _, f in ipairs{ "_now_ms", "_phase_close", "_step", "_phase_emit_timing", "_run" } do
    local body = src:match("\n(" .. f .. "%(%)%s*{\n.-\n})\n")
    if body then got[#got + 1] = body else lost[#lost + 1] = f end
end
T:arm("1 the tracker functions are cut from build.sh", #lost == 0, table.concat(lost, " "))
if #lost > 0 then T:finish() end
local d = T:scratch()
fs.write(d.rel .. "/tracker.sh", table.concat(got, "\n") .. "\n")
local PRE = [==[
set -uo pipefail
SCRIPT_DIR="$1"; W="$2"; FLAG_GRAPHS=true; CYAN=""; NC=""; TILLANDSIAS_HOST_ID=fixturehost
_require_host_build_tools() { :; }
. "$W/tracker.sh"
_PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0
]==]
local function sh(body)
    return T:run{ SH, "-s", "--", ROOT, d.abs, cwd = d.abs, stdin = PRE .. body, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
end
local r = sh [==[
_step "fast guard";  _run true;  sleep 1
_step "slow guard";  _run sleep 1
_step "unmeasured phase"; sleep 1
TILLANDSIAS_TIMING_LOG="$W/t.jsonl" _phase_emit_timing
]==]
local rec, n = {}, 0
for l in (fs.exists(d.rel .. "/t.jsonl") and fs.read(d.rel .. "/t.jsonl") or ""):gmatch("[^\n]+") do
    local ok, j = pcall(json.parse, l)
    if ok and tostring(j.step):sub(1, 5) == "step:" then
        n = n + 1
        for _, k in ipairs{ "fast-guard", "slow-guard", "unmeasured-phase" } do
            if text.contains(j.step, k) then rec[k] = j end
        end
    end
end
local why = "rc=" .. tostring(r.code) .. " " .. (fs.exists(d.rel .. "/t.jsonl") and fs.read(d.rel .. "/t.jsonl") or "no log") .. (r.stderr or ""):sub(1, 300)
local function ms(k) return rec[k] and tonumber(rec[k].duration_ms) end
local function phase(k) return rec[k] and rec[k].phase end
T:arm("2 the fast step excludes the unnamed second after it", ms("fast-guard") and ms("fast-guard") < 400, why)
T:arm("3 the slow step reports its own cost", ms("slow-guard") and ms("slow-guard") >= 900, why)
T:arm("4 both measured steps carry phase=build", phase("fast-guard") == "build" and phase("slow-guard") == "build", why)
T:arm("5a a step with no _run is build-span", phase("unmeasured-phase") == "build-span", why)
T:arm("5b with its wall clock", ms("unmeasured-phase") and ms("unmeasured-phase") >= 900, why)
T:arm("6 three step: records", n == 3, n .. " " .. why)
r = sh 'a=0; _run true >/dev/null 2>&1 || a=$?; b=0; _run sh -c "exit 7" >/dev/null 2>&1 || b=$?; echo "$a $b"\n'
T:arm("7 _run keeps exit 0 and exit 7", text.trim(r.stdout or "") == "0 7", (r.stdout or "") .. (r.stderr or ""))
r = sh [==[
_now_ms() { echo 0; }
_step "stuck clock phase" >/dev/null 2>&1
_run true >/dev/null 2>&1
c=0; TILLANDSIAS_TIMING_LOG="$W/c.jsonl" _phase_emit_timing >/dev/null 2>&1 || c=$?
echo "$c"
]==]
local log = fs.exists(d.rel .. "/c.jsonl") and fs.read(d.rel .. "/c.jsonl") or ""
T:arm("8 a stuck clock degrades to 0 and the emit succeeds", text.trim(r.stdout or "") == "0" and text.contains(log, '"duration_ms":0') and not text.contains(log, '"duration_ms":-'), (r.stdout or "") .. log .. (r.stderr or ""))
T:finish()
