-- @trace order:767-es4w, order:2385-psbb
-- @env PATH HOME
--
-- test-squid-supervisor.lua — hermetic fixtures for images/proxy/squid-supervisor.sh
-- (order 767-es4w). Ported from test-squid-supervisor.sh (2385-psbb); same eight scenarios.
-- No podman, no network, no squid: the real script runs on this host with a scratch state dir.
--
-- Scenarios 3 and 5 fire the SAME signal (SIGSEGV) and demand DIFFERENT verdicts; the only
-- difference is whether the supervisor was asked to stop first. Each is the other's mutation
-- control (idle squid 6.9 and 6.12 both segfault inside exit() after "Exiting normally").
--
--   1  clean exit passes through silently (rc=0, no output, no state dir)
--   2  ordinary failure passes through untouched (rc=3, silent, no restart)
--   3  unsolicited SIGSEGV -> counted fail:proxy-crashed on both streams, evidence, one restart
--   4  flap cap: 3 launches, giveup verdict, truthful rc=139
--   5  forwarded TERM + exit-time SIGSEGV -> note:proxy-exit-teardown-crash, rc 0, not restarted,
--      not counted (BOUNDED: a lost discrimination is an endless restart loop, not a mislabel)
--   6  plain ordered shutdown emits no verdict and writes no state
--   7  missing command refuses with rc=2
--   8  wiring: entrypoint execs the supervisor, image COPY+chmod; negative control on a stripped copy
--
-- Children are script FILES (proc.run denies `bash -c`); 5 and 6 need a background
-- supervisor and an outside TERM, so a short posix_shell driver does exactly the .sh's
-- spawn/kill/bounded-wait. TILLANDSIAS_* is stripped and the PROXY knobs passed per
-- scenario. No build.sh child: gate_inherit n/a.
--
-- GRAMMAR ok:squid-supervisor:<n> arms | violation:squid-supervisor:<n>-failed
--       | refused:squid-supervisor:<reason>

local fixture = require "common.fixture"
local T = fixture.new("squid-supervisor")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local SUP_REL = "images/proxy/squid-supervisor.sh"
if not fs.exists(SUP_REL) then T:refuse("subject-missing", SUP_REL) end
local SUP = ROOT .. "/" .. SUP_REL
local W = T:scratch()
local UNSET = { "TILLANDSIAS_*" }

local function child(name, body)
    fs.write(W.rel .. "/" .. name, "#!/bin/bash\n" .. body .. "\n")
    return W.abs .. "/" .. name
end
-- argv built by table.insert: a `...` followed by named fields keeps only its first value.
local function argv_of(head, ...)
    local a = {}
    for _, v in ipairs(head) do a[#a + 1] = v end
    for _, v in ipairs({ ... }) do a[#a + 1] = v end
    return a
end
local function sup(e, ...)
    local a = argv_of({ SH, SUP, "squid" }, ...)
    a.env, a.env_unset, a.timeout_ms = e, UNSET, 60000
    return T:run(a)
end
local function rd(rel) return fs.exists(rel) and text.trim(fs.read(rel)) or nil end
local function lines_of(rel) return fs.exists(rel) and #text.lines(fs.read(rel)) or 0 end
local function has_line(s, want) for _, l in ipairs(text.lines(s or "")) do if l == want then return true end end return false end
local function st(n) return { rel = W.rel .. "/s" .. n, abs = W.abs .. "/s" .. n } end

-- 1
local s = st(1)
local r = T:run{ SH, SUP, "squid", "true", env = { TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs }, env_unset = UNSET }
local o = (r.stdout or "") .. (r.stderr or "")
T:arm("1 clean exit passes through silently (rc=0, no output, no state dir)",
    r.code == 0 and o == "" and not fs.exists(s.rel), "rc=" .. tostring(r.code) .. " out='" .. o .. "'")

-- 2
s = st(2)
r = sup({ TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs }, SH, child("exit3.sh", "exit 3"))
o = (r.stdout or "") .. (r.stderr or "")
T:arm("2 ordinary failure passes through untouched (rc=3, silent, no restart)",
    r.code == 3 and o == "", "rc=" .. tostring(r.code) .. " out='" .. o .. "'")

-- 3 REAL crash: the child segfaults on launch 1, exits 0 on launch 2.
s = st(3)
local m3 = W.rel .. "/launches3"; fs.write(m3, "")
r = sup({ TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs, TILLANDSIAS_PROXY_BACKOFF_MAX = "1" }, SH,
    child("crash-once.sh", "echo x >> '" .. W.abs .. "/launches3'; if [ $(wc -l < '" .. W.abs
        .. "/launches3') -ge 2 ]; then exit 0; fi; kill -SEGV $$"))
local v3 = "fail:proxy-crashed:service=squid:signal=11:rc=139:crashes=1:recent=1:window=300:action=restart:backoff=1"
local ev3 = rd(s.rel .. "/last-event") or ""
T:arm("3 unsolicited SIGSEGV -> counted crash verdict on both streams, evidence, bounded restart, recovery rc=0",
    r.code == 0 and has_line(r.stdout, v3) and has_line(r.stderr, v3) and lines_of(m3) == 2
        and rd(s.rel .. "/crash-count") == "1" and rd(s.rel .. "/exit-teardown-count") == "0"
        and has_line(ev3, "kind: crash"),
    "rc=" .. tostring(r.code) .. " launches=" .. lines_of(m3) .. " count=" .. tostring(rd(s.rel .. "/crash-count"))
        .. " out=" .. (r.stdout or ""))

-- 4 flap cap
s = st(4)
local m4 = W.rel .. "/launches4"; fs.write(m4, "")
r = sup({ TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs, TILLANDSIAS_PROXY_RESTART_MAX = "2",
    TILLANDSIAS_PROXY_BACKOFF_MAX = "1" }, SH,
    child("crash-always.sh", "echo x >> '" .. W.abs .. "/launches4'; kill -SEGV $$"))
o = (r.stdout or "") .. (r.stderr or "")
T:arm("4 flap cap honoured — 3 launches, giveup verdict, truthful rc=139",
    r.code == 139 and lines_of(m4) == 3
        and text.contains(o, "fail:proxy-crashed:service=squid:signal=11:rc=139:crashes=3:recent=3:window=300:action=giveup")
        and has_line(rd(s.rel .. "/last-event") or "", "kind: giveup"),
    "rc=" .. tostring(r.code) .. " launches=" .. lines_of(m4) .. " out=" .. o)

-- Background driver for 5 and 6: start the supervisor, TERM it after $3 s, wait at most
-- $4 tenths; prints "alive" (then kills it) or "rc=<n>".
local DRIVER = [[
out="$1"; err="$2"; pause="$3"; limit="$4"; shift 4
"$@" >"$out" 2>"$err" &
p=$!
sleep "$pause"
kill -TERM "$p" 2>/dev/null
w=0
while kill -0 "$p" 2>/dev/null && [ "$w" -lt "$limit" ]; do sleep 0.1; w=$((w + 1)); done
if kill -0 "$p" 2>/dev/null; then
    echo alive; pkill -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; exit 0
fi
wait "$p" 2>/dev/null
echo "rc=$?"
]]
local function background(n, e, pause, limit, ...)
    local a = argv_of({ SH, "-s", "--", W.abs .. "/s" .. n .. ".out", W.abs .. "/s" .. n .. ".err",
        pause, limit, SH, SUP, "squid" }, ...)
    a.stdin, a.env, a.env_unset, a.timeout_ms = DRIVER, e, UNSET, 60000
    local res = T:run(a)
    return text.trim(res.stdout or "")
end

-- 5 THE SQUID CASE: TERM forwarded, the child dies of SIGSEGV on the way out.
s = st(5)
local m5 = W.rel .. "/launches5"; fs.write(m5, "")
local d5 = background(5, { TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs }, "1", "100", SH,
    child("teardown.sh", "echo x >> '" .. W.abs .. "/launches5'; trap 'kill -SEGV $$' TERM; while :; do sleep 0.2; done"))
local o5, e5 = rd(W.rel .. "/s5.out") or "", rd(W.rel .. "/s5.err") or ""
local v5 = "note:proxy-exit-teardown-crash:service=squid:signal=11:rc=139:teardowns=1:action=normalised-to-0"
T:arm("5 ordered shutdown + exit-time SIGSEGV -> named teardown note, rc normalised to 0, NOT restarted, NOT counted as a crash",
    d5 == "rc=0" and has_line(o5, v5) and has_line(e5, v5) and lines_of(m5) == 1
        and not text.contains(o5, "fail:proxy-crashed")
        and rd(s.rel .. "/exit-teardown-count") == "1" and rd(s.rel .. "/crash-count") == "0",
    d5 .. " (alive = still running 10s after TERM: ordered shutdown became a restart loop) launches="
        .. lines_of(m5) .. " teardowns=" .. tostring(rd(s.rel .. "/exit-teardown-count"))
        .. " crashes=" .. tostring(rd(s.rel .. "/crash-count")) .. " out=" .. o5)

-- 6 plain ordered shutdown stays silent.
s = st(6)
local d6 = background(6, { TILLANDSIAS_PROXY_CRASH_STATE_DIR = s.abs }, "0.5", "50", "sleep", "30")
local o6 = (rd(W.rel .. "/s6.out") or "") .. (rd(W.rel .. "/s6.err") or "")
T:arm("6 plain ordered shutdown emits NO verdict and writes no state",
    d6 ~= "alive" and o6 == "" and not fs.exists(s.rel), d6 .. " out='" .. o6 .. "'")

-- 7 usage refusal
r = T:run{ SH, SUP, "only-one-arg", env_unset = UNSET }
T:arm("7 missing command refuses with rc=2", r.code == 2, "rc=" .. tostring(r.code))

-- 8 wiring, with a stripped-copy negative control (634-39ik).
local function count(src, needle)
    local n = 0
    for _, l in ipairs(text.lines(src)) do if text.contains(l, needle) then n = n + 1 end end
    return n
end
local entry = fs.read("images/proxy/entrypoint.sh") or ""
local cf = fs.read("images/proxy/Containerfile") or ""
local EXEC = "exec /usr/local/bin/squid-supervisor squid squid -N"
local stripped = {}
for _, l in ipairs(text.lines(entry)) do
    if not text.contains(l, "squid-supervisor") then stripped[#stripped + 1] = l end
end
local wired, copied = count(entry, EXEC), count(cf, "squid-supervisor.sh")
local chmodded, neg = count(cf, "/usr/local/bin/squid-supervisor"), count(table.concat(stripped, "\n"), EXEC)
T:arm("8 wiring — entrypoint execs the supervisor, image COPY+chmod present; negative control red on a stripped copy",
    wired == 1 and copied >= 1 and chmodded >= 1 and neg == 0,
    string.format("wired=%d copied=%d chmodded=%d neg=%d", wired, copied, chmodded, neg))

T:finish()
