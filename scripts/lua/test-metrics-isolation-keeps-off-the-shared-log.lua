-- @trace order:2244-ge9s, order:2365-mskt
--
-- test-metrics-isolation-keeps-off-the-shared-log.lua — gate step 380
-- (scripts/lua/test-gate-step-metrics-isolation.lua) runs in the litmus lane BESIDE
-- the checkout lane (2156-glan). Its negative control provokes a split on
-- purpose, and it used to provoke it into the host's shared
-- /tmp/tillandsias-timing.jsonl while carrying the gate's inherited run id, so
-- the step being watched in the other lane was evicted as "leaked … ours=1"
-- (#1369 on 285-1235-rfub, #1349). It also rm -f'd that shared file and
-- restored it at exit, so the evidence was gone by the time anyone looked.
--
-- This runs the fixture under a GATE-SHAPED env (a run id and a private
-- fallback dir, as build.sh exports them) and watches, WHILE IT RUNS, both
-- places a gate's leak check reads: the shared path and the gate's private
-- fallback. No record carrying the run id may reach either. Read-only: it
-- never writes, truncates or deletes the shared path.
--
-- Measured before the fix on lenovinha (2026-11-23): the shared path gained
-- records carrying the probe's run id during arm 3.
--
-- Then the leak itself (2365-mskt): in a scratch copy of the tree whose
-- metrics-log-path.sh ignores TILLANDSIAS_METRICS_FALLBACK_DIR, the fixture must red AND
-- write nothing to the absolute fallback, here a scratch stand-in for /tmp.
--
-- Verdict: ok:metrics-isolation-off-shared-log:<n> | violation:metrics-isolation-off-shared-log:<failed>/<n>

local fixture = require "common.fixture"
local root = fixture.repo_root()
local SH = fixture.posix_shell()
local PB = fixture.plan_binary()
if PB == "" then verdict.emit("could-not-run:metrics-isolation-off-shared-log:no-plan-binary", 3) end

local RUN = "probe2244-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local SHARED = "/tmp/tillandsias-timing.jsonl"

-- One bash process runs the fixture in the background and polls both logs
-- every 50 ms until it exits; the runtime has no non-blocking wait.
local script = [[
set -u
fb="$(mktemp -d "${TMPDIR:-/tmp}/probe2244-gatefb.XXXXXX")" || exit 3
trap 'rm -rf "$fb"' EXIT
TILLANDSIAS_TIMING_RUN_ID="$RUN" TILLANDSIAS_METRICS_FALLBACK_DIR="$fb" \
    "$TILLANDSIAS_PLAN_BIN" script run scripts/lua/test-gate-step-metrics-isolation.lua >"$fb.out" 2>&1 &
pid=$!
hs=0; hp=0
probe() {
    [ -f "$SHARED" ] && grep -qF "\"run_id\":\"$RUN\"" "$SHARED" 2>/dev/null && hs=1
    [ -f "$fb/tillandsias-timing.jsonl" ] && grep -qF "\"run_id\":\"$RUN\"" "$fb/tillandsias-timing.jsonl" 2>/dev/null && hp=1
}
while kill -0 "$pid" 2>/dev/null; do probe; sleep 0.05; done
wait "$pid"; rc=$?
probe
last="$(tail -n 1 "$fb.out")"; rm -f "$fb.out"
printf 'rc=%s shared=%s private=%s last=%s\n' "$rc" "$hs" "$hp" "$last"
]]
local r = proc.run{ argv = { SH, "-s" }, stdin = script, cwd = root, timeout_ms = 900000,
    env = { RUN = RUN, SHARED = SHARED, TILLANDSIAS_PLAN_BIN = PB, TILLANDSIAS_SCRIPT_RUNNER_BIN = PB } }
local line = text.trim(r.stdout or "")
local rc, hs, hp, last = line:match("^rc=(%d+) shared=(%d) private=(%d) last=(.*)$")
if not rc then verdict.emit("could-not-run:metrics-isolation-off-shared-log:harness:" .. line .. " status=" .. tostring(r.status) .. " reason=" .. tostring(r.reason or r.error or r.message) .. " code=" .. tostring(r.code) .. " err=" .. text.trim(r.stderr or ""), 3) end

local pass, failn = 0, 0
local function check(name, cond, why)
    if cond then pass = pass + 1; out.line("ok:   " .. name)
    else failn = failn + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
check("the fixture itself is green under a gate-shaped env",
    rc == "0" and last:find("ok:step-metrics-isolation:", 1, true) == 1, "rc=" .. rc .. " last=" .. last)
check("no record carrying the gate's run id reached the shared " .. SHARED,
    hs == "0", "a concurrent step in another lane is charged with ours=1 for it")
check("no record carrying the gate's run id reached the gate's private fallback",
    hp == "0", "the gate's private-fallback check would charge it to the watched step")

local T = fixture.new("metrics-isolation-leak")
local c = T:git_repo("copy")
fs.mkdir(c.rel .. "/shared"); fs.mkdir(c.rel .. "/target")
for _, d in ipairs{ "scripts", "lib", "openspec", "build.sh" } do T:must{ "cp", "-R", root .. "/" .. d, c.abs .. "/" .. d } end
local lib, n = fs.read("scripts/metrics-log-path.sh"):gsub('_mdl_fb="%${TILLANDSIAS_METRICS_FALLBACK_DIR:%-[^}]*}"',
    '_mdl_fb="${TILLANDSIAS_NO_SUCH_KNOB:-' .. c.abs .. '/shared}"')
fs.write(c.rel .. "/scripts/metrics-log-path.sh", lib)
local m = T:run{ PB, "script", "run", "scripts/lua/test-gate-step-metrics-isolation.lua", cwd = c.abs, timeout_ms = 600000,
    env = { TILLANDSIAS_PLAN_BIN = PB, TILLANDSIAS_SCRIPT_RUNNER_BIN = PB }, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR", "GIT_*" } }
local said = ((m.stdout or "") .. (m.stderr or "")):gsub("\n", " | ")
check("the fixture reds at arm 3 when the fallback-dir knob is broken", n == 1 and m.code == 1 and said:find("FAIL: 3 ", 1, true) ~= nil,
    "mutated " .. n .. " rc=" .. tostring(m.code) .. " " .. said)
check("and it writes nothing to the absolute fallback", #fs.list(c.rel .. "/shared") == 0, "leaked " .. #fs.list(c.rel .. "/shared") .. " file(s)")
T:cleanup()

local total = pass + failn
if failn == 0 then verdict.ok("metrics-isolation-off-shared-log:" .. total) end
verdict.emit("violation:metrics-isolation-off-shared-log:" .. failn .. "/" .. total, 1)
