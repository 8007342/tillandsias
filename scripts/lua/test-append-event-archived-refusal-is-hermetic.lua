-- @env PATH HOME
-- @trace order:1564-lk9f, order:896-f8ti, order:2367-wtse
--
-- test-append-event-archived-refusal-is-hermetic.lua — the archived-refusal fixture leaves no write
-- in the checkout it runs from, however it dies. Ported from the .sh of the same name (2367-wtse).
-- Measured 2026-10-09: the fixture wrote into the live plan/index.d and relied on an EXIT trap, and
-- a trap does not run on SIGKILL. Each arm runs it in a scratch checkout; a shim plan binary marks
-- the moment the live-accept append-event returned, so the kill is timed and not slept for.
--
--   1 SIGKILL there: the checkout is clean    2 NC a refused live packet still reds the fixture
--   3 an uninterrupted run passes, runs the live-accept arm, and is clean
--
-- Usage: tillandsias-plan script run scripts/lua/test-append-event-archived-refusal-is-hermetic.lua
-- Verdict: ok:append-event-archived-refusal-is-hermetic:<n> arms | violation:... | skip:...:no-setsid

local fixture = require "common.fixture"
local T = fixture.new("append-event-archived-refusal-is-hermetic")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local w = T:scratch()
fs.mkdir(w.rel .. "/shim")
local SHIM = ([==[#!/usr/bin/env bash
case "$*" in
    *"699-usxc preserved"*)
        if [ "@MODE@" = refuse ]; then echo "error: refused by the hermetic shim" >&2; exit 1; fi
        "@PLAN@" "$@"; rc=$?
        if [ "$rc" -eq 0 ] && [ "@MODE@" = kill ]; then echo $$ >"@MARK@"; exec sleep 15; fi
        exit "$rc" ;;
esac
exec "@PLAN@" "$@"
]==])
local SCRIPT = [==[
set -u
R="$1"; P="$2"; MODE="$3"; W=$PWD; C="$W/$MODE"
command -v setsid >/dev/null 2>&1 || exit 9
chmod +x "$W/shim/tillandsias-plan"
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME" "$C/plan" "$C/target"; unset CARGO_TARGET_DIR
cp -R "$R/scripts" "$R/lib" "$C/" && cp -R "$R/plan/index.yaml" "$R/plan/index.d" "$R/plan/archive" "$C/plan/" && cp "$R/.gitignore" "$C/" || exit 90
mkdir -p "$C/.tillandsias"; cp -R "$R/.tillandsias/." "$C/.tillandsias/" 2>/dev/null
G="git -C $C -c user.email=f@example.invalid -c user.name=f -c commit.gpgsign=false"
git -C "$C" init -q && $G add -A && $G commit -qm seed || exit 91
cd "$C" || exit 92
export TILLANDSIAS_PLAN_BIN="$W/shim/tillandsias-plan"
F=scripts/lua/test-append-event-archived-refusal.lua
if [ "$MODE" = kill ]; then
    setsid "$P" script run "$F" >"$W/kill.out" 2>&1 </dev/null &
    pid=$!; n=0
    while [ ! -s "$W/mark" ] && kill -0 "$pid" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.2; n=$((n + 1)); done
    [ -s "$W/mark" ] && echo yes >"$W/marked" || echo no >"$W/marked"
    kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    # The door runs its child in a group of its own, so the shim outlives the group kill.
    [ ! -s "$W/mark" ] || kill -KILL "$(cat "$W/mark")" 2>/dev/null
else
    "$P" script run "$F" >"$W/$MODE.out" 2>&1 </dev/null; echo $? >"$W/$MODE.rc"
fi
git status --porcelain >"$W/$MODE.dirt"
exit 0
]==]
-- The runner scrubs the environment, so the shim carries its values.
local function shim(mode) fs.write(w.rel .. "/shim/tillandsias-plan", (SHIM:gsub("@(%u+)@", { MODE = mode, PLAN = PLAN, MARK = w.abs .. "/mark" }))) end
local function run(mode)
    shim(mode)
    local r = T:run{ SH, "-s", "--", ROOT, PLAN, mode, cwd = w.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 300000 }
    if r.code == 9 then T:skip("no-setsid") end
    if r.code ~= 0 then T:refuse("setup-failed", mode .. " rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
    local function read(f) return fs.exists(w.rel .. "/" .. f) and fs.read(w.rel .. "/" .. f) or "" end
    local x = { out = read(mode .. ".out"), rc = text.trim(read(mode .. ".rc")), dirt = read(mode .. ".dirt"), marked = text.trim(read("marked")) }
    x.why = "rc=" .. x.rc .. " marked=" .. x.marked .. " dirt=[" .. x.dirt:sub(1, 200) .. "] " .. x.out:sub(1, 500)
    T:run{ "rm", "-rf", w.abs .. "/" .. mode }
    return x
end
local x = run("kill")
T:arm("1a PREMISE the live-accept append-event had returned when it was killed", x.marked == "yes", x.why)
T:arm("1b SIGKILL there leaves the checkout clean", x.marked == "yes" and x.dirt == "", x.why)
x = run("refuse")
T:arm("2 NC a refused live packet still reds the fixture, on that arm", x.rc ~= "" and x.rc ~= "0" and text.contains(x.out, "FAIL: 4 a live packet still accepts events"), x.why)
x = run("clean")
T:arm("3 an uninterrupted run passes, exercises the arm, and is clean", x.rc == "0" and x.dirt == "" and text.contains(x.out, "ok:   4 a live packet still accepts events"), x.why)
T:finish()
