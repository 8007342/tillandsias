-- @trace order:767-nkkq, order:2312-d2gf, spec:default-image
--
-- test-harness-supervisor.lua — hermetic arms for images/default/
-- harness-supervisor.sh. Each one runs the real script on this host with a
-- throwaway evidence dir. Ported from the .sh (2312-d2gf).
--
--   1 a clean exit passes through: rc 0, ZERO output, no evidence dir
--   2 an ordinary failure passes through: rc kept, silent
--   3 a fatal signal: the named verdict on stdout AND stderr, an evidence file
--     carrying signal/rc/pointer, the child ran EXACTLY ONCE, rc kept
--   4 SIGTERM is forwarded (bounded exit), and an ordered shutdown is no crash
--   5 an EXTERNAL kill of the child alone (the OOM-killer shape) is still loud
--   6 a missing command is refused with rc 2
--   7 the entrypoints and the image are wired, and the matcher reds on a copy
--     with the supervisor stripped (634-39ik)
--
-- Verdict: ok:harness-supervisor:7 arms | violation:harness-supervisor:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("harness-supervisor")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local SUP = ROOT .. "/images/default/harness-supervisor.sh"
local W = T:scratch()
-- A gate's (or a forge's) own TILLANDSIAS_* names would reach the supervisor.
local DROP = { "TILLANDSIAS_*" }

local function sup(ev, argv, extra)
    local a = { SH, SUP, env_unset = DROP, timeout_ms = 30000,
        env = { TILLANDSIAS_CRASH_EVIDENCE_DIR = W.abs .. "/" .. ev } }
    for k, v in pairs(extra or {}) do a.env[k] = v end
    for _, x in ipairs(argv) do a[#a + 1] = x end
    return T:run(a)
end
local function said(r) return (r.stdout or "") .. (r.stderr or "") end
local function line(s, l) return ("\n" .. (s or "") .. "\n"):find("\n" .. l .. "\n", 1, true) ~= nil end

local r = sup("ev1", { "testh", "true" })
T:arm("1 a clean exit passes through silently", r.code == 0 and said(r) == "" and not fs.exists(W.rel .. "/ev1"), "rc=" .. tostring(r.code) .. " " .. said(r))

fs.write(W.rel .. "/three.sh", "exit 3\n")
r = sup("ev2", { "testh", SH, W.abs .. "/three.sh" })
T:arm("2 an ordinary failure passes through untouched", r.code == 3 and said(r) == "", "rc=" .. tostring(r.code) .. " " .. said(r))

fs.write(W.rel .. "/crash.sh", 'echo x >> "$1"\nkill -SEGV $$\n')
fs.write(W.rel .. "/launches", "")
r = sup("ev3", { "testh", SH, W.abs .. "/crash.sh", W.abs .. "/launches" }, { TILLANDSIAS_CRASH_LAST_OUTPUT = W.abs .. "/lifecycle.log" })
local verdict_line = "fail:harness-crashed:harness=testh:signal=11:rc=139"
local names = T:run{ "ls", W.abs .. "/ev3", timeout_ms = 10000 }.stdout or ""
local report = names:match("crash%-testh%-[^\n]*%.txt")
local body = report and fs.read(W.rel .. "/ev3/" .. report) or ""
T:arm("3 SIGSEGV: verdict on both streams, evidence kept, one launch, rc 139",
    r.code == 139 and line(r.stdout, verdict_line) and line(r.stderr, verdict_line)
    and fs.read(W.rel .. "/launches") == "x\n" and line(body, "signal: 11") and line(body, "rc: 139")
    and body:find("last_output_pointer: " .. W.abs .. "/lifecycle.log", 1, true) ~= nil
    and body:find("no restart attempted", 1, true) ~= nil,
    "rc=" .. tostring(r.code) .. " launches=" .. fs.read(W.rel .. "/launches") .. " report=" .. tostring(report) .. " " .. said(r) .. body)

-- $1 the supervisor, $2 its output file, $3 who is signalled. Waits for the
-- child, then a moment more: the supervisor records its pid just after the fork.
fs.write(W.rel .. "/signal.sh", [[
"$BASH" "$1" testh sleep 30 >"$2" 2>&1 & sup=$!
child=""; i=0
while [ -z "$child" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); child="$(pgrep -P "$sup" | head -1)"; done
sleep 0.5
if [ -z "$child" ]; then echo "no-child"; kill -KILL "$sup"; exit 1; fi
if [ "$3" = child ]; then kill -KILL "$child"; else kill -TERM "$sup"; fi
i=0
while kill -0 "$sup" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$sup" 2>/dev/null; then echo "alive"; kill -KILL "$child" "$sup" 2>/dev/null; wait "$sup" 2>/dev/null; exit 0; fi
wait "$sup" 2>/dev/null
echo "rc=$?"
]])
local function signalled(ev, who)
    local s = T:run{ SH, W.abs .. "/signal.sh", SUP, W.abs .. "/" .. ev .. ".out", who, env_unset = DROP, timeout_ms = 60000,
        env = { TILLANDSIAS_CRASH_EVIDENCE_DIR = W.abs .. "/" .. ev } }
    return text.trim(s.stdout or ""), fs.exists(W.rel .. "/" .. ev .. ".out") and fs.read(W.rel .. "/" .. ev .. ".out") or ""
end
local how, text4 = signalled("ev4", "supervisor")
T:arm("4 SIGTERM is forwarded, the exit is bounded, and an ordered shutdown is no crash",
    how:find("^rc=") ~= nil and not text4:find("harness-crashed", 1, true) and not fs.exists(W.rel .. "/ev4"), how .. " " .. text4)
local how5, text5 = signalled("ev4b", "child")
T:arm("5 an external SIGKILL of the child alone is still loud (rc 137)",
    how5 == "rc=137" and text5:find("fail:harness-crashed:harness=testh:signal=9:rc=137", 1, true) ~= nil, how5 .. " " .. text5)

r = sup("ev5", { "only-one-arg" })
T:arm("6 a missing command is refused with rc 2", r.code == 2, "rc=" .. tostring(r.code))

local function count(s, want)
    local n = 0
    for _, l in ipairs(text.lines(s)) do if l:find(want, 1, true) then n = n + 1 end end
    return n
end
local OC = "exec /usr/local/bin/harness-supervisor opencode"
local oc = fs.read("images/default/entrypoint-forge-opencode.sh")
local cx = fs.read("images/default/entrypoint-forge-codex.sh")
local stripped = {}
for _, l in ipairs(text.lines(oc)) do
    if not l:find("harness-supervisor", 1, true) then stripped[#stripped + 1] = l end
end
local w = { oc = count(oc, OC), cx = count(cx, "exec /usr/local/bin/harness-supervisor codex"),
    copied = count(fs.read("images/default/Containerfile"), "/usr/local/bin/harness-supervisor"),
    direct = count(oc, 'exec "$OC_BIN" "$@"'), neg = count(table.concat(stripped, "\n"), OC) }
T:arm("7 wiring: 2 opencode + 1 codex supervised lanes, image COPY+chmod, interactive lane direct; red on a stripped copy",
    w.oc == 2 and w.cx == 1 and w.copied >= 2 and w.direct == 1 and w.neg == 0,
    ("oc=%d cx=%d copied=%d direct=%d neg=%d"):format(w.oc, w.cx, w.copied, w.direct, w.neg))
T:finish()
