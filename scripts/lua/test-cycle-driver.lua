-- @env PATH HOME
-- @trace order:856-s56y, order:2306-y8sg
--
-- test-cycle-driver.lua — scripts/tillandsias-cycle-driver.sh through its TILLANDSIAS_CYCLE_*
-- seams: no agent, systemd unit or network. Ported from the .sh of the same name (2306-y8sg);
-- same eight arms, each in its own root.
--
--   1 success passes through (rc 0)          2 failure passes through (rc 1, loud)
--   3 a live holder makes the fire a SKIP    4 the lock is free again afterwards
--   5-7 the same with no flock(1) on PATH, as on stock macOS, where an unconditional flock
--       read command-not-found as "held" and skipped every fire: 5 fires and releases its
--       lock directory, 6 skips on a live holder, 7 reclaims a dead one
--   8 MUTATION CONTROL: with the liveness test neutered, 6's scenario FIRES
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-driver.lua
-- Verdict: ok:cycle-driver:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-driver")
local SH = fixture.posix_shell()
local DRIVER = fs.read("scripts/tillandsias-cycle-driver.sh")
local NEUTERED
do
    local i, j = DRIVER:find('kill -0 "$_holder" 2>/dev/null', 1, true)
    if not i then T:refuse("mutation-did-not-apply", "the no-flock liveness test moved") end
    NEUTERED = DRIVER:sub(1, i - 1) .. "false" .. DRIVER:sub(j + 1)
end

-- The caller's shell takes the lock (if asked) and stays alive across the fire, so its pid is
-- a live holder. `farm` hides flock: a PATH of symlinks to the tools the driver needs.
local SCRIPT = [==[
set -u
cmd=$1 farm=$2 hold=$3; W=$PWD; mkdir -p root state
git -C root init -q || exit 90
L="$W/root/.git/tillandsias-cycle.lock"
export TILLANDSIAS_CYCLE_ROOT="$W/root" TILLANDSIAS_CYCLE_STATE_DIR="$W/state" TILLANDSIAS_CYCLE_CMD="$cmd"
dir() { mkdir "$L.d" && printf '%s\n' "$1" >"$L.d/pid" && date +%s >"$L.d/epoch" || exit 91; }
case $hold in
  live) if [ "$farm" = no ] && command -v flock >/dev/null 2>&1; then exec 8>"$L"; flock -n 8 || exit 92; else dir $$; fi ;;
  dead) dir 99999999 ;;
esac
B="$(command -v bash)" P=$PATH
if [ "$farm" = yes ]; then
  mkdir farm
  for t in bash sh git date mkdir cat rm uname cut tail dirname grep; do p="$(type -P "$t")" && ln -s "$p" "farm/$t"; done
  B="$W/farm/bash" P="$W/farm"
  ( PATH="$P"; hash -r; type -P flock >/dev/null ) && exit 93
fi
rc=0; PATH="$P" "$B" "$W/driver.sh" </dev/null >out 2>/dev/null || rc=$?
if [ -d "$L.d" ]; then echo held >lockdir; else echo free >lockdir; fi
if [ "$hold" = live ] && [ "$farm" = no ]; then
  exec 8>&-; rm -rf "$L.d"; "$B" "$W/driver.sh" </dev/null >again 2>/dev/null
fi
exit $rc
]==]
local function fire(cmd, farm, hold, driver)
    local d = T:scratch()
    fs.write(d.rel .. "/driver.sh", driver or DRIVER)
    local r = proc.run{ argv = { SH, "-s", "--", cmd, farm and "yes" or "no", hold or "no" }, cwd = d.abs, stdin = SCRIPT, timeout_ms = 60000 }
    if r.code and r.code >= 90 then T:refuse("setup-failed", "rc " .. r.code .. " " .. (r.stderr or "")) end
    local function read(f) return fs.exists(d.rel .. "/" .. f) and text.trim(fs.read(d.rel .. "/" .. f)) or "" end
    local f = { rc = r.code, verdict = read("out"):match("([^\n]*)$"), log = read("state/cycle-scheduler.jsonl"):match("([^\n]*)"),
        lock = read("lockdir"), again = read("again"):match("([^\n]*)$") }
    f.why = "rc=" .. tostring(f.rc) .. " [" .. f.verdict .. "] " .. f.log .. " lock=" .. f.lock
    return f
end
local FIRED, SKIP = "ok:cycle-fired:rc=0", "skip:overlap-lock-held"

local f = fire("true")
T:arm("1 success passes through", f.rc == 0 and f.verdict == FIRED and text.contains(f.log, '"rc":0,"skipped":false'), f.why)
f = fire("false")
T:arm("2 failure passes through, loud", f.rc == 1 and f.verdict == "fail:cycle-driver:rc=1" and text.contains(f.log, '"rc":1,"skipped":false'), f.why)
f = fire("true", false, "live")
T:arm("3 a live holder makes the fire a skip", f.rc == 0 and f.verdict == SKIP and text.contains(f.log, '"skipped":true'), f.why)
T:arm("4 the lock is free again once the holder lets go", f.again == FIRED, f.again)
f = fire("true", true)
T:arm("5 no flock: fires and releases its lock directory", f.rc == 0 and f.verdict == FIRED and f.lock == "free", f.why)
f = fire("true", true, "live")
T:arm("6 no flock: a live holder skips and keeps its lock", f.rc == 0 and f.verdict == SKIP and f.lock == "held", f.why)
f = fire("true", true, "dead")
T:arm("7 no flock: a dead holder is reclaimed and released", f.rc == 0 and f.verdict == FIRED and f.lock == "free", f.why)
f = fire("true", true, "live", NEUTERED)
T:arm("8 CONTROL with the liveness test neutered a live holder no longer skips", f.verdict == FIRED, f.why)
T:finish()
