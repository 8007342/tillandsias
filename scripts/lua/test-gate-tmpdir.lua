-- @trace order:2118-77ew, spec:ci-release
-- @env PATH
--
-- test-gate-tmpdir.lua — litmus:gate-leaves-nothing-in-tmp.
-- Operator 2026-11-20 (landing-pipeline P2): a gate leaves 0 new /tmp
-- entries. The gate runs under scripts/gate-tmpdir.sh, which gives the whole
-- run ONE private TMPDIR and removes it at the end, whatever the outcome.
-- Each arm points the PARENT TMPDIR at a fresh scratch dir and counts what is
-- left in it afterwards.
--   NEGATIVE CONTROL: with the wrapper switched off, a child that makes a
--   temp dir leaves it behind (the arms can see a leak).
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-tmpdir.lua
-- Verdict: ok:gate-tmpdir:<n> arms | violation:gate-tmpdir:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-tmpdir")
local ROOT = fixture.repo_root()
local W = ROOT .. "/scripts/gate-tmpdir.sh"

local function entries(d)
    local r = T:run{ "ls", "-A", d.abs }
    local n = 0
    for l in (r.stdout or ""):gmatch("[^\n]+") do n = n + 1 end
    return n, r.stdout or ""
end
local function run(d, argv, extra)
    local e = { PATH = env.get("PATH"), TMPDIR = d.abs }
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.env = e
    argv.cwd = ROOT
    return T:run(argv)
end

-- NEGATIVE CONTROL
local c = T:scratch("control")
run(c, { W, "run", "mktemp", "-d" }, { TILLANDSIAS_GATE_TMPDIR_OFF = "1" })
T:arm("control: without the wrapper a child's temp dir is left behind", (entries(c)) == 1,
    "nothing left — the arms cannot see a leak")

-- 1. a child's temp files land in the private dir, which is gone afterwards
local d = T:scratch("clean")
local r = run(d, { W, "run", "mktemp", "-d" })
local made = text.trim(r.stdout or "")
T:arm("the child's TMPDIR is a private tg.* dir under the parent",
    made:find(d.abs .. "/tg.", 1, true) == 1, made)
local n, ls = entries(d)
T:arm("after the run the parent TMPDIR has 0 new entries", n == 0, ls)

-- 2. the child's exit code is the wrapper's
local f = T:scratch("rc")
local rf = run(f, { W, "run", "sh", "-c", "exit 7" })
T:arm("the child's exit code passes through", rf.code == 7, tostring(rf.code))
T:arm("a failing run cleans up too", (entries(f)) == 0, select(2, entries(f)))

-- 2b. under `set -e` (build.sh's mode) a failing child still cleans up.
-- Measured: the first real red gate left its tg.* dir, because `wait` failing
-- under set -e ended the wrapper before its rm.
local e = T:scratch("set-e")
local re = run(e, { W, "run-errexit", "sh", "-c", "exit 3" })
T:arm("under set -e a failing run returns its code", re.code == 3, tostring(re.code))
T:arm("under set -e a failing run leaves 0 new entries", (entries(e)) == 0, select(2, entries(e)))

-- 3. TERM reaches the child, and the dir is still removed
local k = T:scratch("term")
local t0 = time.now_ms()
local rk = run(k, { "timeout", "-s", "TERM", "1", W, "run", "sleep", "30" })
local took = time.now_ms() - t0
T:arm("TERM is forwarded: the child stops instead of running 30 s", took < 10000, tostring(took) .. " ms")
T:arm("a TERMinated run leaves 0 new entries", (entries(k)) == 0, select(2, entries(k)))
T:arm("a TERMinated run exits non-zero", rk.code ~= 0, tostring(rk.code))

-- 4. nested: an inner gate reuses the outer dir (one dir per outermost gate)
local nd = T:scratch("nested")
local rn = run(nd, { W, "run", W, "run", "sh", "-c", 'printf "%s %s" "$TMPDIR" "$TILLANDSIAS_GATE_TMPDIR"' })
local a, b = (rn.stdout or ""):match("^(%S+) (%S+)$")
T:arm("a nested gate runs in the outer gate's dir", a ~= nil and a == b and a:find("/tg.", 1, true) ~= nil,
    tostring(rn.stdout))

-- 5. stdin reaches the child
local s = T:scratch("stdin")
local rs = run(s, { W, "run", "cat", stdin = "through\n" })
T:arm("stdin is passed to the child", rs.stdout == "through\n", tostring(rs.stdout))

T:finish()
