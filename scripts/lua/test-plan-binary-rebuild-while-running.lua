-- @env PATH
-- @trace order:2187-sdtz
--
-- test-plan-binary-rebuild-while-running.lua — scripts/plan-binary-probe.sh's
-- rebuild succeeds while the stale tillandsias-plan.exe is RUNNING (the Lua
-- runner that sourced the probe). Windows refuses to delete a running image
-- (cargo: "failed to remove file ... Access is denied (os error 5)") but allows
-- renaming it; the probe sets the old .exe aside before cargo links.
--
-- A scratch tree holds target/release/tillandsias-plan.exe, a copy of a real
-- executable (PING.EXE on Windows, a native image; sleep elsewhere), started and left running. `cargo` is a stub that does
-- what cargo does to the artifact: remove it, then write the new one.
--   1 the rebuild returns 0 while the old image runs, and the artifact is the new one
--     (RED before 2187-sdtz on msys: the stub's rm is refused, rc 1)
--   2 a failed build puts the old binary back (nothing is lost)
--   3 a set-aside copy left by an earlier run is swept once its process exited
--   4 while cargo runs, a binary is still at the real path (a reap mid-build
--     left only .old-<pid> in the first version of this fix)
-- Off Windows a running file can be removed anyway, so arms 1-3 pass there
-- for the trivial reason; the regime that matters is msys.
--
-- Verdict: ok:plan-binary-rebuild-while-running:<n> arms | violation:...:<n>-failed
local fixture = require "common.fixture"
local T = fixture.new("plan-binary-rebuild-while-running")
local ROOT = fixture.repo_root()

-- The shell the probe is written for. A native Windows process resolves a bare
-- `bash` to WSL's, so derive Git's bash from git's own exec path.
local BASH = "bash"
local ep = T:run{ "git", "--exec-path" }
local gp = text.trim(ep.stdout or "")
if gp:find("^%a:/.*/libexec/git%-core$") then  -- mingw64/ or ucrt64/, per Git build
    BASH = (gp:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe"))
end

local S = T:scratch("tree")
fs.mkdir(S.rel .. "/target/release")

-- One bash body per arm; $1 = repo root (for the probe), $2 = arm.
local BODY = [=[
set -u
PROBE="$1/scripts/plan-binary-probe.sh"
. "$PROBE"
EXE=target/release/tillandsias-plan.exe
# A NATIVE image is what Windows locks (an msys sleep.exe can be removed while
# it runs, so it would prove nothing): use ping.exe there, sleep elsewhere.
if [ -f /c/Windows/System32/PING.EXE ]; then SLEEP=/c/Windows/System32/PING.EXE; ARGS="-n 30 127.0.0.1"
else SLEEP="$(command -v sleep)"; ARGS=30; fi
cp "$SLEEP" "$EXE"
case "$2" in
  1|2|4) "./$EXE" $ARGS >/dev/null 2>&1 & PID=$! ; sleep 1 ;;
  3)   cp "$SLEEP" "$EXE.old-424242" ; PID="" ;;
esac
# Remove the artifact the way cargo does. msys rm uses POSIX-delete semantics,
# which Windows grants even on a running image; cargo's Win32 DeleteFile is
# refused (os error 5). So on Windows delete through .NET, which is DeleteFile.
rm_like_cargo() {
  [ -e "$EXE" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    powershell -NoProfile -c "[IO.File]::Delete('$(cygpath -w "$PWD/$EXE")')" >/dev/null 2>&1
  else rm -f "$EXE"; fi
}
if [ "$2" = 4 ]; then
  cargo() { [ -f "$EXE" ] && echo present > during; return 1; }
elif [ "$2" = 2 ]; then
  cargo() { rm_like_cargo; return 1; }
else
  cargo() { rm_like_cargo || return 1; printf 'NEW' > "$EXE"; }
fi
_pbp_cargo_build >/dev/null 2>&1; rc=$?
if [ ! -f "$EXE" ]; then content=none; elif [ "$(head -c 3 "$EXE")" = NEW ]; then content=NEW; else content=old; fi
olds="$(ls "$EXE".old-* 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$PID" ] && kill "$PID" 2>/dev/null; wait 2>/dev/null
echo "rc=$rc content=$content olds=$olds during=$(cat during 2>/dev/null || echo absent)"; rm -f during
]=]
fs.write(S.rel .. "/arm.sh", BODY)

local function arm(n)
    local r = T:run{ BASH, "arm.sh", ROOT, tostring(n), cwd = S.abs, timeout_ms = 60000 }
    return text.trim(r.stdout or "") .. (r.code ~= 0 and (" exit=" .. r.code .. " " .. (r.stderr or "")) or "")
end

local o1 = arm(1)
T:arm("1 rebuild while the old image runs: rc 0, the artifact is the new one",
    o1:find("rc=0 content=NEW", 1, true) ~= nil, o1)
local o2 = arm(2)
T:arm("2 a failed build puts the old binary back",
    o2:find("rc=1 content=old olds=0", 1, true) ~= nil, o2)
local o3 = arm(3)
T:arm("3 an exited set-aside copy is swept", o3:find("rc=0 content=NEW olds=0", 1, true) ~= nil, o3)
local o4 = arm(4)
T:arm("4 while cargo runs, a runnable binary is still at the real path (a kill mid-build loses nothing)",
    o4:find("during=present", 1, true) ~= nil, o4)

T:finish()
