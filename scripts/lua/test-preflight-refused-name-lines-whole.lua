-- @trace order:1563-u2yx, spec:ci-release, order:2375-psb9
-- @env PATH HOME
--
-- test-preflight-refused-name-lines-whole.lua — fixture for scripts/lib-wsl-capture.sh
-- (order 1563-u2yx). Ported from test-preflight-refused-name-lines-whole.sh (2375-psb9); same
-- seven arms, same verdict name (wsl-capture-fixture). Runs on any Linux or MSYS host: a stub
-- wsl.exe REOPENS its stderr target by path, the independent-offset write wsl.exe does on
-- Windows (measured on yolanda 2026-10-08: `> f 2>&1` kept 25600 of 38000 bytes, 3/3 runs).
-- The stub prints what build.sh's preflight prints: skip notices on stdout, refusal blocks
-- ending refused:preflight:<name> on stderr. Skips where /proc/<pid>/fd is absent (macOS).
--
--   1  caller captures `> log 2>&1`: all 40 refused:preflight:<name> lines survive, equal the
--      summary's refused=N, no byte is lost, and the capture path ran (stub is a CHILD)
--   2  wsl.exe's exit code is the wrapper's
--   3  a PIPE caller keeps the exec path (the stub IS the wrapper's pid)
--   4  two DISTINCT files keep the exec path
--   5  TERM to the wrapper on the capture path reaches wsl.exe, and nothing survives it
--   6  stdin still reaches wsl.exe on the capture path
--   7  with-wsl2-builder.sh reaches wsl.exe for the build only through the lib
--
-- Each arm's redirection is the subject, so each runs as a small shell script on stdin.
-- PRE-FIX RESULT: FAILS — with a plain exec, arm 1 loses refusal lines.
--
-- GRAMMAR ok:wsl-capture-fixture:<n> arms | violation:wsl-capture-fixture:<n>-failed
--       | skip:wsl-capture-fixture:no-proc-fd | refused:wsl-capture-fixture:lib-missing

local fixture = require "common.fixture"
local T = fixture.new("wsl-capture-fixture")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local LIB = ROOT .. "/scripts/lib-wsl-capture.sh"
if not fs.exists("scripts/lib-wsl-capture.sh") then T:refuse("lib-missing", LIB) end
if T:run{ SH, "-s", stdin = '[ -r /proc/$$/fd/1 ]\n' }.code ~= 0 then T:skip("no-proc-fd") end

local W = T:scratch()
-- The stub: records its pid and parent, reopens stderr by path when it is a regular file
-- (fresh offset 0, as wsl.exe does), then acts per $STUB_MODE.
fs.write(W.rel .. "/wsl.exe", [[
#!/usr/bin/env bash
echo "$$ $PPID" > "$STUB_DIR/stub.pid"
t="$(readlink "/proc/$$/fd/2" 2>/dev/null)"
[ -n "$t" ] && [ -f "$t" ] && exec 2<>"$t"
case "${STUB_MODE:-preflight}" in
    preflight)
        n=0
        while [ "$n" -lt 40 ]; do
            echo "skip:preflight:guard-$n:deadline:183s — outlived the 180s front-door deadline; the gate still runs it"
            printf 'FAIL: arm 5: an unanswerable discipline question -> blocked:…:discipline-unanswered, rc 1\n  why: the guard guard-%s refused this tree\nrefused:preflight:guard-%s\n' "$n" "$n" >&2
            n=$((n + 1))
        done
        echo "refused:preflight:ran=0 refused=40 sum=40" >&2 ;;
    rc) exit 7 ;;
    sleep)
        trap 'echo got-term > "$STUB_DIR/stub.term"; exit 143' TERM
        echo started > "$STUB_DIR/stub.started"
        while :; do sleep 0.1; done ;;
    stdin) read -r line; echo "stdin:$line" ;;
esac
]])
T:must{ "chmod", "+x", W.abs .. "/wsl.exe" }
-- The wrapper under test: a shell that records its own pid, then hands over.
fs.write(W.rel .. "/wrapper.sh", 'echo $$ > "' .. W.abs .. '/wrapper.pid"\n. "' .. LIB .. '"\n'
    .. "tillandsias_wsl_exec -d tillandsias-build -- bash -c true\n")

local ENV = { STUB_DIR = W.abs, TILLANDSIAS_WSL_EXE = W.abs .. "/wsl.exe", W = W.abs, SHELL_BIN = SH }
local function sh(script)
    return T:run{ SH, "-s", cwd = W.abs, env = ENV, env_unset = { "TILLANDSIAS_*" }, stdin = script, timeout_ms = 60000 }
end
-- Each script prints key=value lines; this reads them.
local function kv(r)
    local f = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local k, v = l:match("^([%w_]+)=(.*)$")
        if k then f[k] = v end
    end
    return f
end
local NAMED = [[grep -c '^refused:preflight:guard-[0-9]*$']]

-- 1: the measured case. (The stub run into a pipe does not reopen: it is the full text.)
local f = kv(sh([[
expected="$(STUB_MODE=preflight "$W/wsl.exe" 2>&1 | wc -c | tr -d ' ')"
STUB_MODE=preflight "$SHELL_BIN" "$W/wrapper.sh" > "$W/log" 2>&1
echo "named=$(]] .. NAMED .. [[ "$W/log")"
echo "summary=$(grep -o 'refused=[0-9]*' "$W/log" | tail -1)"
echo "bytes=$(wc -c < "$W/log" | tr -d ' ')"
echo "expected=$expected"
read -r spid sppid < "$W/stub.pid"; echo "sppid=$sppid"; echo "wpid=$(cat "$W/wrapper.pid")"
]]))
T:arm("1 > log 2>&1 keeps all 40 refused:preflight:<name> lines = refused=40, every byte, via the capture path",
    f.named == "40" and f.summary == "refused=40" and f.bytes ~= nil and f.bytes == f.expected and f.sppid == f.wpid,
    string.format("named=%s summary=%s bytes=%s/%s stub-ppid=%s wrapper=%s",
        tostring(f.named), tostring(f.summary), tostring(f.bytes), tostring(f.expected), tostring(f.sppid), tostring(f.wpid)))

-- 2: the exit code.
f = kv(sh('STUB_MODE=rc "$SHELL_BIN" "$W/wrapper.sh" > "$W/log2" 2>&1; echo "rc=$?"\n'))
T:arm("2 wsl.exe's exit code (7) is the wrapper's", f.rc == "7", "rc=" .. tostring(f.rc))

-- 3: a pipe caller keeps exec.
f = kv(sh([[
out="$(STUB_MODE=preflight "$SHELL_BIN" "$W/wrapper.sh" 2>&1 | cat)"
echo "named=$(printf '%s\n' "$out" | ]] .. NAMED .. [[)"
read -r spid sppid < "$W/stub.pid"; echo "spid=$spid"; echo "wpid=$(cat "$W/wrapper.pid")"
]]))
T:arm("3 a pipe caller keeps the exec path (stub pid = wrapper pid)", f.spid ~= nil and f.spid == f.wpid and f.named == "40",
    "stub=" .. tostring(f.spid) .. " wrapper=" .. tostring(f.wpid) .. " named=" .. tostring(f.named))

-- 4: two distinct files keep exec.
f = kv(sh([[
STUB_MODE=preflight "$SHELL_BIN" "$W/wrapper.sh" > "$W/out4" 2> "$W/err4"
echo "named=$(]] .. NAMED .. [[ "$W/err4")"
read -r spid sppid < "$W/stub.pid"; echo "spid=$spid"; echo "wpid=$(cat "$W/wrapper.pid")"
]]))
T:arm("4 distinct stdout/stderr files keep the exec path", f.spid ~= nil and f.spid == f.wpid and f.named == "40",
    "stub=" .. tostring(f.spid) .. " wrapper=" .. tostring(f.wpid))

-- 5: TERM to the wrapper reaches wsl.exe, and nothing survives it.
f = kv(sh([[
STUB_MODE=sleep "$SHELL_BIN" "$W/wrapper.sh" > "$W/log5" 2>&1 &
bg=$!
i=0; while [ ! -f "$W/stub.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
read -r spid sppid < "$W/stub.pid"
kill -TERM "$bg"
i=0; while kill -0 "$bg" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
wait "$bg" 2>/dev/null; echo "rc=$?"
alive=0; kill -0 "$spid" 2>/dev/null && alive=1; echo "alive=$alive"
[ "$alive" -eq 0 ] || kill -KILL "$spid" 2>/dev/null
[ -f "$W/stub.term" ] && echo "term=yes" || echo "term=no"
]]))
T:arm("5 TERM to the wrapper reached wsl.exe (rc 143), nothing survived",
    f.term == "yes" and f.alive == "0" and f.rc == "143",
    "term-seen=" .. tostring(f.term) .. " stub-alive=" .. tostring(f.alive) .. " rc=" .. tostring(f.rc))

-- 6: stdin reaches wsl.exe on the capture path.
f = kv(sh('echo hello | STUB_MODE=stdin "$SHELL_BIN" "$W/wrapper.sh" > "$W/log6" 2>&1\necho "got=$(cat "$W/log6")"\n'))
T:arm("6 stdin reaches wsl.exe on the capture path", f.got == "stdin:hello", "[" .. tostring(f.got) .. "]")

-- 7: wired: no build-path wsl.exe call bypasses the lib.
local B = fs.read("scripts/with-wsl2-builder.sh") or ""
local bypass, uses = {}, 0
for _, l in ipairs(text.lines(B)) do
    if l:find('^%s*wsl%.exe%s+%-d "%$BUILD_DISTRO" %-u root %-%-cd') or l:find('^%s*exec%s+wsl%.exe%s+%-d "%$BUILD_DISTRO" %-u root %-%-cd') then
        bypass[#bypass + 1] = l
    end
    if l:find('^%s*tillandsias_wsl_exec %-d "%$BUILD_DISTRO" %-u root %-%-cd')
        or l:find('^%s*tillandsias_wsl_run %-d "%$BUILD_DISTRO" %-u root %-%-cd') then uses = uses + 1 end
end
T:arm("7 with-wsl2-builder.sh reaches wsl.exe for the build only through the lib (6 sites: 3 in-tree, 3 for the source mirror, 667-kfyn)",
    #bypass == 0 and uses == 6 and text.contains(B, "lib-wsl-capture.sh"),
    "uses=" .. uses .. " bypass=[" .. table.concat(bypass, "|") .. "]")

T:finish()
