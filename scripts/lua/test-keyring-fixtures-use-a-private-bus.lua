-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:1903-djsq, order:2118-9kqp, order:2378-hcxg
--
-- test-keyring-fixtures-use-a-private-bus.lua — the credential fixtures pass, and none reaches the
-- session bus it inherited. Ported from the .sh of the same name (2378-hcxg). Each runs with
-- DBUS_SESSION_BUS_ADDRESS set to a SENTINEL dbus-daemon watched for NameOwnerChanged, so one that
-- reaches the bus it inherited is a count there; the operator's bus is never touched. This is the
-- only place the gate runs them.
--
--   0 population   1 CONTROL a bare busctl registers on the sentinel (the instrument is not deaf)
--   2 each fixture made no bus event   3 each takes the private bus (holds with no dbus-daemon too)
--   4 each fixture's own verdict       5 CONTROLS planted fixtures: one that reaches the bus is
--     counted, one with a private bus is not, a failing one is judged failed
--
-- Usage: tillandsias-plan script run scripts/lua/test-keyring-fixtures-use-a-private-bus.lua
-- Verdict: ok:keyring-fixtures-use-a-private-bus:<n> arms | violation:... |
--   skip:keyring-fixtures-use-a-private-bus:bus-arm:no-dbus-daemon (the other arms passed)

local fixture = require "common.fixture"
local T = fixture.new("keyring-fixtures-use-a-private-bus")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local FIXTURES = {
    "scripts/test-check-credential-channel.sh",
    "scripts/lua/test-credential-channel-survives-a-killed-probe.lua",
    "scripts/lua/test-credential-channel-names-a-locked-keyring.lua",
    "scripts/lua/test-credential-channel-affordances.lua",
    "scripts/lua/test-clear-vault-host-credentials.lua",
    "scripts/lua/test-clear-vault-credentials-partial-is-nonzero.lua",
    "scripts/lua/test-credential-verdict-script.lua",
}
T:arm("0 the population is the seven", #FIXTURES == 7, tostring(#FIXTURES))
local function private(body, lua)
    if lua then
        -- Every child gets bus.env, and none inherits the runner's.
        return text.contains(body, 'require "common.privatebus"') and text.contains(body, "bus.env") and not text.contains(body, "env = { PATH")
    end
    return ("\n" .. body):find("\n%s*%.%s[^\n]*test%-support/private%-session%-bus%.sh") ~= nil
end
for _, f in ipairs(FIXTURES) do
    local there = fs.exists(f)
    T:arm("0 " .. f .. " exists", there, "missing")
    if there then T:arm("3 " .. f .. " takes the private bus", private(fs.read(f), f:match("%.lua$") ~= nil), "it does not") end
end
local w = T:scratch()
local BARE = 'local r = proc.run{ argv = { "busctl", "--user", "list", "--no-pager" }, timeout_ms = 10000 }\n'
fs.write(w.rel .. "/reaches.lua", BARE .. "verdict.ok('planted-reaches')\n")
fs.write(w.rel .. "/private.lua", '-- @env PATH HOME\nlocal bus = require "common.privatebus"\nlocal r = proc.run{ argv = { "busctl", "--user", "list", "--no-pager" }, env = bus.env(), timeout_ms = 10000 }\nverdict.ok("planted-private")\n')
fs.write(w.rel .. "/fails.lua", "verdict.emit('violation:planted-fails:1-failed', 1)\n")
fs.write(w.rel .. "/private.sh", ". \"" .. ROOT .. "/scripts/test-support/private-session-bus.sh\"\nbusctl --user list --no-pager >/dev/null 2>&1\necho ok:planted-private-shell\n")
local PLANTED = { w.rel .. "/reaches.lua", w.rel .. "/private.lua", w.rel .. "/fails.lua", w.rel .. "/private.sh" }
local SCRIPT = [==[
set -u
W="$1"; P="$2"; shift 2
DP=""; MP=""; SD=""
trap '[ -z "$MP" ] || kill "$MP" 2>/dev/null; [ -z "$DP" ] || kill "$DP" 2>/dev/null; [ -z "$SD" ] || rm -r "$SD"' EXIT
conns() { c="$(grep -c 'member=NameOwnerChanged' "$W/mon" 2>/dev/null)"; echo "${c:-0}"; }
settle() { sleep 0.3; }
if command -v dbus-daemon >/dev/null 2>&1 && command -v dbus-monitor >/dev/null 2>&1 && command -v busctl >/dev/null 2>&1; then
    SD="$(mktemp -d "${TMPDIR:-/tmp}/kfpb.XXXXXX")"  # short: a socket path has a limit
    dbus-daemon --session --nofork --nopidfile --address="unix:path=$SD/s" --print-address=1 >"$W/addr" 2>"$W/daemon.err" </dev/null & DP=$!
    i=0; while [ ! -s "$W/addr" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    read -r SENTINEL <"$W/addr" || SENTINEL=""
    [ -n "$SENTINEL" ] || { echo "bus=did-not-start"; cat "$W/daemon.err"; exit 0; }
    export DBUS_SESSION_BUS_ADDRESS="$SENTINEL"
    dbus-monitor --address "$SENTINEL" "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'" >"$W/mon" 2>&1 </dev/null & MP=$!
    i=0; while ! grep -q NameOwnerChanged "$W/mon" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    settle; b="$(conns)"; busctl --user list --no-pager >/dev/null 2>&1; settle
    echo "bus=up"; echo "control=$(($(conns) - b))"
else
    echo "bus=none"
fi
n=0
for f in "$@"; do
    n=$((n + 1)); b=0; [ -z "$MP" ] || b="$(conns)"; rc=0
    case "$f" in *.lua) "$P" script run "$f" >"$W/out.$n" 2>&1 </dev/null || rc=$? ;; *) bash "$f" >"$W/out.$n" 2>&1 </dev/null || rc=$? ;; esac
    d=0; [ -z "$MP" ] || { settle; d=$(($(conns) - b)); }
    echo "run $n rc=$rc events=$d"
done
echo end
]==]
local argv = { SH, "-s", "--", w.abs, PLAN }
for _, l in ipairs{ FIXTURES, PLANTED } do
    for _, f in ipairs(l) do argv[#argv + 1] = f end
end
-- XDG_RUNTIME_DIR stays: the address is honoured before it. The .sh fixture needs what it inherits.
local r = proc.run{ argv = argv, cwd = ROOT, stdin = SCRIPT, env_unset = { "TILLANDSIAS_REPO_ROOT", "TILLANDSIAS_SCRIPT_RUNNER_BIN" }, timeout_ms = 280000 }
local o = "\n" .. (r.stdout or "")
T:arm("every fixture was run", text.contains(o, "\nend\n"), tostring(r.status) .. " " .. o:sub(-300) .. (r.stderr or ""):sub(-300))
local bus = o:match("\nbus=(%S+)")
T:arm("the sentinel came up, or there is no dbus here", bus == "up" or bus == "none", o:sub(1, 400))
if bus == "up" then T:arm("1 CONTROL a bare busctl registers on the sentinel", (tonumber(o:match("\ncontrol=(%-?%d+)")) or 0) > 0, o:sub(1, 200)) end
local function ran(n)
    local rc, events = o:match("\nrun " .. n .. " rc=(%d+) events=(%-?%d+)")
    local tail = fs.exists(w.rel .. "/out." .. n) and fs.read(w.rel .. "/out." .. n) or ""
    return rc and tonumber(rc), events and tonumber(events), tail
end
-- 0 and a verdict line: an empty run that exits 0 is not a pass.
local function passed(rc, tail) return rc == 0 and ("\n" .. tail):find("\nok:[^\n]+\n?$") ~= nil or rc == 0 and ("\n" .. tail):find("\nskip:[^\n]+\n?$") ~= nil or rc == 0 and ("\n" .. tail):find("\nPASS[^\n]*\n?$") ~= nil end
for n, f in ipairs(FIXTURES) do
    local rc, events, tail = ran(n)
    T:arm("4 " .. f .. " passed", passed(rc, tail), "rc=" .. tostring(rc) .. "\n" .. tail:sub(-1500))
    if bus == "up" then T:arm("2 " .. f .. " made no event on the bus it inherited", events == 0, tostring(events) .. " events; on an operator host that is the real bus and gnome-keyring-daemon (1265-8qr6)") end
end
local rc1, ev1, t1 = ran(#FIXTURES + 1)
local rc2, ev2, t2 = ran(#FIXTURES + 2)
local rc3, _, t3 = ran(#FIXTURES + 3)
local rc4, ev4, t4 = ran(#FIXTURES + 4)
T:arm("5a CONTROL a planted pass is judged passed", passed(rc1, t1) and passed(rc2, t2) and passed(rc4, t4), tostring(rc4) .. t4 .. tostring(rc1) .. t1 .. tostring(rc2) .. t2)
T:arm("5b CONTROL a planted failure is judged failed, and silence is not a pass", rc3 == 1 and not passed(rc3, t3) and not passed(0, ""), tostring(rc3) .. t3)
T:arm("5c CONTROL the static check tells Lua ones apart", not private(BARE, true) and private(fs.read(w.rel .. "/private.lua"), true) and not private(fs.read(w.rel .. "/private.lua") .. "local e = { env = { PATH = 1 } }", true), "it does not")
T:arm("5c and shell ones", not private("# private-session-bus.sh\nbusctl --user list\n", false) and private(". \"$d/test-support/private-session-bus.sh\"\n", false), "it does not")
if bus == "up" then
    T:arm("5d CONTROL a planted fixture that reaches the bus is counted", (ev1 or 0) > 0, tostring(ev1))
    T:arm("5e CONTROL one on the private bus is not, in Lua or shell", ev2 == 0 and ev4 == 0, tostring(ev2) .. " " .. tostring(ev4))
end
if bus == "none" and #T.failed == 0 then T:skip("bus-arm:no-dbus-daemon") end
T:finish()
