-- @env PATH HOME
-- @trace order:1141-vf9w, order:2031-z4rm, order:2377-znx4
--
-- test-dispatch-reap.lua — lib-dispatch-reap.sh kills the processes carrying its own dispatch's
-- token and no others. Ported from the .sh of the same name (2377-znx4). The targets are sleeps this
-- test starts; the tokens are its own.
--
--   1 no proc root: refused by name, rc 2, never a quiet 0     2 tokens are distinct
--   3 a marked process is found, a differently marked one is not, an empty token matches nothing
--   4 the reap kills its own and leaves the other              5 a SIGTERM-inert one is escalated
--   6 an absent token is a no-op       7 the retired variable name still works
--   8 a Lua door child carries the marker
--
-- Usage: tillandsias-plan script run scripts/lua/test-dispatch-reap.lua
-- Verdict: ok:dispatch-reap:<n> arms | violation:... | could-not-run:dispatch-reap:no-proc-no-setsid (3)

local fixture = require "common.fixture"
local T = fixture.new("dispatch-reap")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local w = T:scratch()
local LIB = 'LIB="$2/scripts/lib-dispatch-reap.sh"; W="$1"\n. "$LIB"\n'
local function sh(body)
    local r = proc.run{ argv = { SH, "-s", "--", w.abs, ROOT }, cwd = w.abs, stdin = LIB .. body, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    return { rc = r.code, out = "\n" .. (r.stdout or ""), err = r.stderr or "", why = "rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 500) .. (r.stderr or ""):sub(1, 300) }
end
local x = sh 'TILLANDSIAS_DISPATCH_PROC_ROOT="$W/no-such-proc" tillandsias_reap_marked probe-token >/dev/null'
T:arm("1a with no proc root the reap refuses with rc 2", x.rc == 2, x.why)
T:arm("1b and says so by name", text.contains(x.err, "unsupported:dispatch-reap:no-proc"), x.why)
if #T.failed > 0 then T:finish() end
if sh('tillandsias_dispatch_reap_supported && command -v setsid >/dev/null 2>&1').rc ~= 0 then
    T:cleanup()
    verdict.emit("could-not-run:dispatch-reap:no-proc-no-setsid", 3)
end
x = sh [==[
set -u
say() { echo "$1=$2"; }
pids=""; trap 'for p in $pids; do kill -KILL "$p" 2>/dev/null; done' EXIT
spawn() { env "$1=$2" setsid sleep 120 >/dev/null 2>&1 </dev/null & p=$!; pids="$pids $p"; }
alive() { s="$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" || return 1; case "$s" in ''|Z|X|x) return 1 ;; esac; return 0; }
has() { case "
$(tillandsias_marked_pids "$2" 2>/dev/null)
" in *"
$1
"*) return 0 ;; esac; return 1; }
await() { i=0; while [ "$i" -lt 100 ]; do has "$1" "$2" && return 0; sleep 0.05; i=$((i + 1)); done; return 1; }
gone() { i=0; while [ "$i" -lt 40 ]; do alive "$1" || return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
yn() { if "$@"; then echo yes; else echo no; fi; }
t1="$(tillandsias_dispatch_token)"; t2="$(tillandsias_dispatch_token)"
[ -n "$t1" ] && [ "$t1" != "$t2" ] && say tokens yes || say tokens no
A="fixture-a-$$-$t1"; B="fixture-b-$$-$t2"; R="fixture-r-$$-$t1"; K=TILLANDSIAS_WRAPPER_MARK
spawn $K "$A"; pa=$p; spawn $K "$B"; pb=$p
say found "$(yn await "$pa" "$A")"; say other_visible "$(yn await "$pb" "$B")"; say leaked "$(yn has "$pb" "$A")"
say empty "[$(tillandsias_marked_pids "")]"
tillandsias_reap_marked "$A" >/dev/null 2>&1
say reaped "$(yn gone "$pa")"; say spared "$(yn alive "$pb")"
env "$K=$A" setsid bash -s >/dev/null 2>&1 <<'INERT' &
trap "" TERM
sleep 120
INERT
pd=$!; pids="$pids $pd"; say inert_up "$(yn await "$pd" "$A")"; sleep 0.5
rc=0; tillandsias_reap_marked "$A" 3 >/dev/null 2>&1 || rc=$?
say escalated "$(yn gone "$pd")"; say escalated_rc "$rc"
rc=0; tillandsias_reap_marked "absent-$$-$t2" >/dev/null 2>&1 || rc=$?; say absent_rc "$rc"
spawn TILLANDSIAS_WRAPPER_TOKEN "$R"; pr=$p
say retired_found "$(yn await "$pr" "$R")"; tillandsias_reap_marked "$R" >/dev/null 2>&1; say retired_reaped "$(yn gone "$pr")"
]==]
local function says(k, v) return text.contains(x.out, "\n" .. k .. "=" .. v .. "\n") end
for _, c in ipairs{ { "2 minted tokens are non-empty and distinct", "tokens", "yes" }, { "3a a marked process is found by its token", "found", "yes" }, { "3b PREMISE the other one is visible under its own", "other_visible", "yes" },
    { "3c and is not in this token's kill set", "leaked", "no" }, { "3d an empty token matches nothing", "empty", "[]" }, { "4a the reap kills the marked process", "reaped", "yes" }, { "4b and leaves the other running", "spared", "yes" },
    { "5a PREMISE the SIGTERM-inert process was up", "inert_up", "yes" }, { "5b it is escalated to SIGKILL and reaped", "escalated", "yes" }, { "5c and the reap reports success", "escalated_rc", "0" }, { "6 an absent token is a clean no-op", "absent_rc", "0" },
    { "7a a process carrying only the retired name is found", "retired_found", "yes" }, { "7b and reaped", "retired_reaped", "yes" } } do
    T:arm(c[1], says(c[2], c[3]), x.why)
end
if PLAN == "" then
    out.line("skip: 8 no runnable plan binary")
else
    fs.write(w.rel .. "/probe.lua", "local r = proc.run{argv={'printenv','TILLANDSIAS_WRAPPER_MARK'}}\nif r.status == 'exited' and r.code == 0 then verdict.ok('marker-reached-child') end\nverdict.emit('violation:z4rm:marker-did-not-reach-child', 1)\n")
    local r = T:run{ SH, "-s", "--", PLAN, w.abs .. "/probe.lua", cwd = ROOT, stdin = 'TILLANDSIAS_WRAPPER_MARK=lua-door-fixture exec "$1" script run "$2" </dev/null\n', env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    T:arm("8 a Lua door child carries the marker", r.code == 0 and text.contains(r.stdout or "", "ok:marker-reached-child"), (r.stdout or "") .. (r.stderr or ""))
end
T:finish()
