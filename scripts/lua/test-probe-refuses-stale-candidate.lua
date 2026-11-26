-- @trace order:1172-dyvd, order:1546-b8ba, spec:accel-capability-probe, order:2385-psbb
-- @env PATH HOME
--
-- test-probe-refuses-stale-candidate.lua — fixture for scripts/host-capability-probe.sh's
-- resolver (order 1172-dyvd). Ported from test-probe-refuses-stale-candidate.sh (2385-psbb);
-- same fourteen arms.
--
-- A candidate whose --inference-tier exits 0 only proves it RUNS; this script WRITES THE
-- LEDGER, so a stale-but-runnable binary published a confident wrong capability row (yolanda
-- 2026-09-13: no GPU/NPU reported on a host with both). The resolver must refuse a candidate
-- whose --capabilities omits accel_side, by name. Fakes differ by what they PRINT, never by
-- mtime. Hermetic once the host's own candidates are shadowed: a failing `tillandsias` is
-- prefixed on PATH and the probe runs from scratch (no ./target/release candidate).
-- TILLANDSIAS_* and LOCALAPPDATA never reach the child unless an arm sets them.
--
--   1a a stale candidate is refused (rc=2)          1b ... by name      1c ... naming accel_side
--   2a a current candidate is admitted (rc != 2)    2b ... and not reported stale
--   3  identical-age candidates get opposite resolver verdicts (reads output, not mtime)
--   4  a non-running candidate is not misreported as stale
--   5a a current long-output producer is admitted (1546-b8ba SIGPIPE)  5b ... not reported stale
--   6a a failing producer with partial accel_side output is refused   6b ... by name
--   7a (1171-ccf2) a current binary in the LOCALAPPDATA install dir is consulted
--   7b a stale installed binary is refused by name   7c LOCALAPPDATA unset: no install candidate
--
-- GRAMMAR ok:probe-refuses-stale-candidate:<n> arms | violation:probe-refuses-stale-candidate:<n>-failed
--       | refused:probe-refuses-stale-candidate:<reason>

local fixture = require "common.fixture"
local T = fixture.new("probe-refuses-stale-candidate")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PROBE = ROOT .. "/scripts/host-capability-probe.sh"
if not fs.exists("scripts/host-capability-probe.sh") then T:refuse("subject-missing", PROBE) end

local D = T:scratch()
local function fake(name, body, rel)
    local p = (rel or D.rel) .. "/" .. name
    fs.write(p, "#!/usr/bin/env bash\n" .. body)
    T:must{ "chmod", "+x", ROOT .. "/" .. p }
    return D.abs .. "/" .. name
end

local STALE = [[
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)   echo "accel_class=cpu-only accel_gpu=none accel_npu=none accel_cpu_cores=16"; exit 0 ;;
esac
exit 0
]]
local CURRENT = [[
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)
      echo "accel_class=cpu-only accel_gpu=none accel_npu=none accel_side=windows-host"
      exit 0 ;;
esac
exit 0
]]
local stale = fake("stale", STALE)
local current = fake("current", CURRENT)
-- The real Darwin binary's shape: envelope first, then enough JSON to outlive a close-early matcher.
local current_long = fake("current-long", [[
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)
      printf '%s\n' 'accel_class=cpu-only accel_gpu=none accel_npu=none accel_side=macos-host'
      printf '%s' '{"schema_version":2,"host":{"host_id":"fixture-current-long","host_kind":"macos"},"padding":"'
      i=0
      while [ "$i" -lt 20000 ]; do printf x; i=$((i + 1)); done
      printf '%s\n' '"}'
      exit 0 ;;
esac
exit 0
]])
-- Prints the vocabulary, then fails: partial output is not a usable document.
local failing = fake("failing-partial", [[
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)
      echo 'accel_class=cpu-only accel_gpu=none accel_npu=none accel_side=macos-host'
      exit 73 ;;
esac
exit 0
]])
fs.mkdir(D.rel .. "/shadow")
fake("shadow/tillandsias", "exit 1\n")
local PATHV = D.abs .. "/shadow:" .. (env.get("PATH") or "")

-- stderr only (the .sh's 2>&1 >/dev/null), and rc.
local function probe(e)
    e.PATH = PATHV; e.HOME = env.get("HOME")
    local r = T:run{ SH, PROBE, "--fragment", cwd = D.abs, env = e,
        env_unset = { "TILLANDSIAS_*", "LOCALAPPDATA", "CARGO_TARGET_DIR" }, timeout_ms = 60000 }
    return r.stderr or "", r.code
end
local function refused(o, path) return o:find("refused:probe:stale-candidate:" .. path, 1, true) ~= nil end
local function any_stale(o) return o:find("refused:probe:stale-candidate:", 1, true) ~= nil end

-- 1: the defect.
local o1, rc1 = probe{ TILLANDSIAS_HEADLESS_BIN = stale }
T:arm("1a a stale candidate is refused (rc=2) rather than published", rc1 == 2, "rc=" .. tostring(rc1))
T:arm("1b the refusal NAMES the candidate it refused", refused(o1, stale), o1)
T:arm("1c the refusal says WHICH contract the candidate predates", o1:find("accel_side", 1, true) ~= nil, o1)

-- 2: positive control. The fake has no capability DOCUMENT, so the probe fails later (rc=1);
-- the row owns RESOLUTION, i.e. rc != 2 and no stale line.
local o2, rc2 = probe{ TILLANDSIAS_HEADLESS_BIN = current }
T:arm("2a a current candidate is still ADMITTED by the resolver (rc != 2)", rc2 ~= 2, "rc=" .. tostring(rc2) .. " " .. o2)
T:arm("2b and is not reported as stale", not any_stale(o2), o2)

-- 3: same second, same script: any mtime rule ranks them identically.
T:arm("3 two candidates of identical age get opposite RESOLVER verdicts", rc1 == 2 and rc2 ~= 2,
    "rc1=" .. tostring(rc1) .. " rc2=" .. tostring(rc2))

-- 4: not running is absent, not stale (different remedies).
local broken = fake("broken", "exit 127\n")
local o3 = probe{ TILLANDSIAS_HEADLESS_BIN = broken }
T:arm("4 a non-running candidate is not misreported as stale", not refused(o3, broken), o3)

-- 5: 1546-b8ba: grep -q closed its pipe and pipefail turned SIGPIPE into a false stale refusal.
local o4, rc4 = probe{ TILLANDSIAS_HEADLESS_BIN = current_long }
T:arm("5a a current long-output producer is admitted without a broken-pipe stale refusal", rc4 == 0,
    "rc=" .. tostring(rc4) .. " " .. o4)
T:arm("5b the long-output producer is not reported as stale", not any_stale(o4), o4)

-- 6: partial current-looking output does not override producer failure.
local o5, rc5 = probe{ TILLANDSIAS_HEADLESS_BIN = failing }
T:arm("6a a failing producer with partial accel_side output is not admitted", rc5 == 2, "rc=" .. tostring(rc5) .. " " .. o5)
T:arm("6b the failing partial-output producer is refused by name", refused(o5, failing), o5)

-- 7: ORDER 1171-ccf2. No TILLANDSIAS_HEADLESS_BIN (it pre-empts every later candidate);
-- LOCALAPPDATA is fixture-supplied, and must vanish when unset.
local LOCAL = D.abs .. "/fakelocal"
local IREL = D.rel .. "/fakelocal/Programs/Tillandsias"
T:must{ "mkdir", "-p", ROOT .. "/" .. IREL }
local INST = LOCAL .. "/Programs/Tillandsias/tillandsias.exe"
fake("tillandsias.exe", CURRENT, IREL)
local o6, rc6 = probe{ LOCALAPPDATA = LOCAL }
T:arm("7a a current binary in the install dir is CONSULTED (rc != 2)", rc6 ~= 2, "rc=" .. tostring(rc6) .. " " .. o6)
fake("tillandsias.exe", STALE, IREL)
local o7 = probe{ LOCALAPPDATA = LOCAL }
T:arm("7b a STALE binary in the install dir is refused by name", refused(o7, INST), o7)
fake("tillandsias.exe", CURRENT, IREL)
local o8, rc8 = probe{}
T:arm("7c with LOCALAPPDATA unset the install candidate does not exist (rc 1 or 2)", rc8 == 1 or rc8 == 2,
    "rc=" .. tostring(rc8) .. " " .. o8)

T:finish()
