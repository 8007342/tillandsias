-- @env PATH HOME
-- @trace order:873-zcim, order:1098-q7bk, order:2381-wpqb
--
-- test-cycle-checkout-lock.lua — cycle-checkout-lock.sh lets one lane hold a checkout, names the
-- holder to the next, reclaims a dead one's lock, and refuses an anchor that dies with the tool call.
-- Ported from the .sh of the same name (2381-wpqb). Scratch repositories and state; holders are the
-- script's own shell.
--
--   1 acquire, refuse, foreign release, release   2 a dead holder's lock is reclaimed
--   3 the prompt lane yields to a driver's flock  4 the driver skips a held checkout, and fires after
--   5 a refusal is recorded outside the checkout  6 a bare acquire refuses
--   7 MUTATION without that refusal it acquires over a dead holder
--   8 msys: a live native pid is live, dead ones are dead, and the lock holds
--   9 msys MUTATION without the native branch it reads dead and the checkout free
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-checkout-lock.lua
-- Verdict: ok:cycle-checkout-lock:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-checkout-lock")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LOCK = fs.read("scripts/cycle-checkout-lock.sh"):gsub("\r", "")
local PRE = [==[
set -u
D="$1"; W="$2"; R="$3"; LOCKSH="$R/scripts/cycle-checkout-lock.sh"
unset CLAUDE_PID TILLANDSIAS_CYCLE_HOLDER_PID
export TILLANDSIAS_CYCLE_STATE_DIR="$W/state"
cd "$D" || exit 90
as() { p="$1"; shift; TILLANDSIAS_CYCLE_HOLDER_PID="$p" bash "$LOCKSH" "$@" </dev/null 2>/dev/null | tail -n 1; }
say() { printf '%s=%s\n' "$1" "$2"; }
]==]
local function sh(body, files)
    local g, w = T:git_repo(), T:scratch()
    for n, b in pairs(files or {}) do fs.write(w.rel .. "/" .. n, b) end
    local r = proc.run{ argv = { SH, "-s", "--", g.abs, w.abs, ROOT }, cwd = g.abs, stdin = PRE .. body, env = { PATH = env.get("PATH"), HOME = w.abs }, env_unset = { "TILLANDSIAS_*", "GIT_*", "CLAUDE_PID" }, timeout_ms = 120000 }
    local x = { w = w, why = "rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 500) .. (r.stderr or ""):sub(1, 300) }
    for k, v in (r.stdout or ""):gsub("\r", ""):gmatch("([%w_]+)=([^\n]*)\n") do x[k] = v end
    return x
end
local function starts(v, p) return v ~= nil and v:sub(1, #p) == p end
local FREE, DEAD = "ok:checkout-lock:free", "99999999"
local x = sh [==[
say me "$$"
say first "$(as $$ acquire --lane a --source s1)"; say second "$(as 99999999 acquire --lane b --source s2)"
say foreign "$(as 99999999 release)"; say mine "$(as $$ release)"
]==]
T:arm("1a acquire names its lane and holder", x.first == "ok:checkout-lock:acquired:a:" .. tostring(x.me), x.why)
T:arm("1b a second acquire is refused, the holder named", starts(x.second, "skip:overlap-lock-held:") and text.contains(x.second, "pid=" .. x.me), x.why)
T:arm("1c a non-holder cannot release", starts(x.foreign, "fail:checkout-lock:held-by-other:"), x.why)
T:arm("1d the holder can", x.mine == "ok:checkout-lock:released", x.why)
x = sh 'as 99999999 acquire --lane dead --source s >/dev/null; say me "$$"; say again "$(as $$ acquire --lane new --source s)"\n'
T:arm("2 a dead holder's lock is reclaimed", x.again == "ok:checkout-lock:acquired:new:" .. tostring(x.me), x.why)
if not fixture.which("flock") then
    out.line("skip: 3 no flock here")
else
    x = sh [==[
G="$(git rev-parse --absolute-git-dir)"
( exec 9>"$G/tillandsias-cycle.lock"; flock -n 9 && : >"$W/held" && exec sleep 15 ) & f=$!
i=0; while [ ! -e "$W/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
say held "$([ -e "$W/held" ] && echo yes)"; say yields "$(as $$ acquire --lane loop --source s)"
[ -d "$G/tillandsias-cycle.lock.d" ] && say left yes || say left no
kill "$f" 2>/dev/null; wait "$f" 2>/dev/null
]==]
    T:arm("3a PREMISE a driver held the flock", x.held == "yes", x.why)
    T:arm("3b the prompt lane yields to it", x.yields == "skip:overlap-lock-held:driver-flock", x.why)
    T:arm("3c and leaves no lock behind", x.left == "no", x.why)
end
x = sh [==[
drive() { TILLANDSIAS_CYCLE_ROOT="$D" TILLANDSIAS_CYCLE_CMD=true bash "$R/scripts/tillandsias-cycle-driver.sh" </dev/null 2>/dev/null | tail -n 1; }
as $$ acquire --lane loop --source s >/dev/null; say held "$(drive)"; as $$ release >/dev/null; say after "$(drive)"
]==]
T:arm("4a the driver skips a checkout a prompt lane holds", x.held == "skip:overlap-lock-held", x.why)
T:arm("4b and fires once it is released", x.after == "ok:cycle-fired:rc=0", x.why)
x = sh 'as $$ acquire --lane a --source s >/dev/null; as 99999999 acquire --lane b --source rec-test >/dev/null\n'
local f = x.w.rel .. "/state/overlap-refusals.jsonl"
local rec = fs.exists(f) and fs.read(f) or ""
T:arm("5 the refusal is recorded outside the checkout", text.contains(rec, '"event":"overlap-refused"') and text.contains(rec, '"refused_source":"rec-test"'), rec)

-- A bare acquire, from a shell that is gone when it returns, as a tool call's is.
local BARE = [==[
printf 'cd "%s" && bash "%s" acquire --lane bare --source s\n' "$D" "$LOCKSH" >"$W/w.sh"
say got "$(env -u TILLANDSIAS_CYCLE_HOLDER_PID -u CLAUDE_PID bash "$W/w.sh" </dev/null 2>/dev/null | tail -n 1)"
p="$(cat "$D/.git/tillandsias-cycle.lock.d/pid" 2>/dev/null)"; say holder "$p"
[ -n "$p" ] && kill -0 "$p" 2>/dev/null && say alive yes || say alive no
]==]
x = sh(BARE)
T:arm("6 a bare acquire refuses, or its holder is alive", x.got == "refused:checkout-lock:no-holder-pid" or (starts(x.got, "ok:checkout-lock:acquired:") or starts(x.got, "warn:checkout-lock:acquired-dead-anchor:")) and x.alive == "yes", x.why)
local OPEN, NEXT = "# ORDER 1098-q7bk — REFUSE an UNVERIFIED anchor", "        # 1. The atomic claim among prompt lanes."
local a, b = LOCK:find(OPEN, 1, true), LOCK:find(NEXT, 1, true)
if not a or not b or b < a then
    T:arm("7a the refusal can be cut out", false, "the markers moved")
else
    local line = a
    while line > 1 and LOCK:sub(line - 1, line - 1) ~= "\n" do line = line - 1 end
    local mut = LOCK:sub(1, line - 1) .. LOCK:sub(b)
    T:arm("7a the cut takes the refusal and nothing more", not mut:find("\n%s*echo \"refused:checkout%-lock:no%-holder%-pid\"") and text.contains(mut, "The atomic claim among prompt lanes"), "bad cut")
    x = sh('LOCKSH="$W/mut.sh"\nbash -n "$LOCKSH" && say parses yes\n' .. BARE, { ["mut.sh"] = mut })
    T:arm("7b MUTATION without it, a bare acquire holds over a dead pid", x.parses == "yes" and (starts(x.got, "ok:checkout-lock:acquired:") or starts(x.got, "warn:checkout-lock:acquired-dead-anchor:")) and x.alive == "no", x.why)
end

local sys = text.trim(T:run{ "uname", "-s" }.stdout or "")
if not (sys:match("^MINGW") or sys:match("^MSYS") or sys:match("^CYGWIN")) then
    out.line("skip: 8 9 one pid space on " .. sys)
    T:finish()
end
-- An MSYS child has two pids: kill -0 resolves one and calls the other dead while it runs.
local NATIVE = [==[
sleep 40 & m=$!; sleep 1
n="$(ps 2>/dev/null | awk -v p="$m" '$1 == p { print $4; exit }')"; say native "$n"
[ -n "$n" ] && [ "$n" != "$m" ] && say distinct yes || say distinct no
kill -0 "$m" 2>/dev/null && say msys_live yes; kill -0 "$n" 2>/dev/null && say native_by_kill yes || say native_by_kill no
tasklist //NH //FO CSV //FI "PID eq $n" 2>/dev/null | grep -q "\",\"$n\"," && say tasklist yes
probe() { bash "$LOCKSH" pid-probe --pid "$1" </dev/null 2>/dev/null | tail -n 1; }
say live "$(probe "$n")"; say dead "$(probe 99999999)"; say one "$(probe 1)"
say acquired "$(as "$n" acquire --lane nat --source s)"; say sibling "$(bash "$LOCKSH" status </dev/null 2>/dev/null | tail -n 1)"
kill "$m" 2>/dev/null; wait "$m" 2>/dev/null
]==]
x = sh(NATIVE)
local n = tostring(x.native)
T:arm("8a PREMISE a distinct native pid, live by tasklist", x.distinct == "yes" and x.msys_live == "yes" and x.tasklist == "yes", x.why)
if x.native_by_kill == "yes" then
    out.line("skip: 8b 9 kill -0 resolves the native pid here, so the defect cannot occur")
else
    local m1, m2 = LOCK:find("\n        MINGW*|MSYS*|CYGWIN*)", 1, true)
    local e1 = m2 and LOCK:find("\n    esac\n", m2, true)
    local mut = m1 and e1 and LOCK:sub(1, m1 - 1) .. LOCK:sub(e1)
    T:arm("9a the native branch can be cut out", mut ~= nil and not text.contains(mut, "ps -W 2>/dev/null | awk") and text.contains(mut, "pid_is_live()"), "the markers moved")
    if mut then
        local y = sh('LOCKSH="$W/mut.sh"\nbash -n "$LOCKSH" && say parses yes\n' .. NATIVE, { ["mut.sh"] = mut })
        T:arm("9b MUTATION without it a live native pid reads dead and the checkout free", y.parses == "yes" and starts(y.live, "ok:pid-probe:dead:" .. tostring(y.native) .. ":") and y.sibling == FREE, y.why)
    end
end
T:arm("8c pid-probe sees the live native pid", starts(x.live, "ok:pid-probe:live:" .. n .. ":"), x.why)
T:arm("8d and calls a nonexistent pid, and pid 1, dead", starts(x.dead, "ok:pid-probe:dead:" .. DEAD .. ":") and starts(x.one, "ok:pid-probe:dead:1:"), x.why)
T:arm("8e acquire on it is clean", x.acquired == "ok:checkout-lock:acquired:nat:" .. n, x.why)
T:arm("8f and a sibling lane is refused", starts(x.sibling, "skip:overlap-lock-held:") and text.contains(x.sibling, "pid=" .. n), x.why)
T:finish()
