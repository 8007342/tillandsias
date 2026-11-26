-- @env PATH HOME
-- @trace order:873-zcim, order:2367-wtse
--
-- test-cycle-lock-attested-release.lua — an attested holder's checkout lock is reclaimed by the next
-- cycle, a live unattested one is not, and a lock is never taken over an anchor about to die. Ported
-- from the .sh of the same name (2367-wtse). A scratch repository and state directory; the
-- holders are the script's own shell and a sleep it starts.
--
--   1 the parent-pid probe agrees with another mechanism   2 attested: reclaimed
--   3 unattested and live: refused   4 mark-attested by the holder's descendant writes the marker
--   5 by an unrelated pid: refused, nothing written        6 with no lock: a clean no-op
--   7 a bare acquire refuses, names the variable, leaves no lock
--   8 CONTROL CLAUDE_PID alone, 9 CONTROL the explicit anchor: clean acquires
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-lock-attested-release.lua
-- Verdict: ok:cycle-lock-attested-release:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-lock-attested-release")
local SH = fixture.posix_shell()
local g, w = T:git_repo(), T:scratch()
fs.mkdir(g.rel .. "/scripts")
fs.write(g.rel .. "/scripts/cycle-checkout-lock.sh", fs.read("scripts/cycle-checkout-lock.sh"))
T:must{ "chmod", "+x", g.abs .. "/scripts/cycle-checkout-lock.sh" }
T:must{ "git", "-C", g.abs, "add", "-A" }; T:must{ "git", "-C", g.abs, "commit", "-qm", "seed" }
local SCRIPT = [==[
set -u
R="$1"; W="$2"; L="$R/.git/tillandsias-cycle.lock.d"
unset CLAUDE_PID
export TILLANDSIAS_CYCLE_STATE_DIR="$W/state"
sleep 300 </dev/null >/dev/null 2>&1 & other=$!
trap 'kill "$other" 2>/dev/null' EXIT
cd "$R" || exit 90
held() { rm -rf "$L"; mkdir -p "$L"; echo "$1" >"$L/pid"; date +%s >"$L/epoch"; echo loop-cron >"$L/lane"; echo fixture >"$L/source"; [ "${2:-}" != attested ] || date +%s >"$L/attested"; }
run() { n="$1"; h="$2"; shift 2; TILLANDSIAS_CYCLE_HOLDER_PID="$h" ./scripts/cycle-checkout-lock.sh "$@" >"$W/$n" 2>&1 </dev/null; }
run probe "$$" ppid-probe --pid "$$"
t=""; [ ! -r "/proc/$$/stat" ] || t="$(awk '{ print $4 }' "/proc/$$/stat" 2>/dev/null)"
[ -n "$t" ] || t="$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')"
echo "$t" >"$W/ppid"
held "$other" attested; run attested "$$" acquire --lane loop-cron --source fixture
held "$other"; run live "$$" acquire --lane loop-cron --source fixture
held "$$"; run mark 999999 mark-attested; [ -f "$L/attested" ] && echo yes >"$W/mark.file" || echo no >"$W/mark.file"
held "$other"; run foreign "$$" mark-attested; [ -f "$L/attested" ] && echo yes >"$W/foreign.file" || echo no >"$W/foreign.file"
rm -rf "$L"; run nolock "$$" mark-attested
rm -rf "$L"; env -u TILLANDSIAS_CYCLE_HOLDER_PID ./scripts/cycle-checkout-lock.sh acquire --lane prompt --source bare >"$W/bare" 2>&1 </dev/null
[ -d "$L" ] && echo yes >"$W/bare.lock" || echo no >"$W/bare.lock"
rm -rf "$L"; env -u TILLANDSIAS_CYCLE_HOLDER_PID CLAUDE_PID="$$" ./scripts/cycle-checkout-lock.sh acquire --lane prompt --source harness >"$W/harness" 2>&1 </dev/null
rm -rf "$L"; run recipe "$$" acquire --lane prompt --source recipe
exit 0
]==]
local r = T:run{ SH, "-s", "--", g.abs, w.abs, cwd = g.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*", "GIT_*", "CLAUDE_PID" }, timeout_ms = 120000 }
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
local function read(f) return fs.exists(w.rel .. "/" .. f) and fs.read(w.rel .. "/" .. f):gsub("\r", "") or "" end
local function says(f, prefix) return read(f):sub(1, #prefix) == prefix end
local ACQ = "ok:checkout-lock:acquired:"
local probed, truth = read("probe"):match("^ok:ppid%-probe:(%S+)"), text.trim(read("ppid"))
T:arm("1 the parent-pid probe resolves, and agrees where another mechanism can say", probed ~= nil and (truth == "" or probed == truth), read("probe") .. " truth=" .. truth)
T:arm("2 an attested holder's lock is reclaimed", says("attested", ACQ), read("attested"))
T:arm("3 an unattested live holder still refuses", says("live", "skip:overlap-lock-held:"), read("live"))
T:arm("4 mark-attested accepts the holder's descendant and writes the marker", says("mark", "ok:checkout-lock:marked-attested") and text.trim(read("mark.file")) == "yes", read("mark") .. read("mark.file"))
T:arm("5 it refuses a lock an unrelated live pid holds, and writes nothing", says("foreign", "fail:checkout-lock:held-by-other:") and text.trim(read("foreign.file")) == "no", read("foreign") .. read("foreign.file"))
T:arm("6 with no lock it is a clean no-op", says("nolock", "ok:checkout-lock:no-lock-held"), read("nolock"))
T:arm("7a a bare acquire refuses, naming the variable", says("bare", "refused:checkout-lock:no-holder-pid") and text.contains(read("bare"), "TILLANDSIAS_CYCLE_HOLDER_PID"), read("bare"))
T:arm("7b and leaves no lock for the next lane to reap", text.trim(read("bare.lock")) == "no", read("bare.lock"))
T:arm("8 CONTROL CLAUDE_PID alone acquires cleanly", says("harness", ACQ), read("harness"))
T:arm("9 CONTROL so does the explicit anchor", says("recipe", ACQ), read("recipe"))
T:finish()
