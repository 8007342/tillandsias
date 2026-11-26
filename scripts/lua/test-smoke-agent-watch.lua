-- @trace order:1275-ngrc, spec:meta-orchestration, order:2360-psb8
-- @env PATH HOME
--
-- test-smoke-agent-watch.lua — the smoke forge lane detects the agent-dead-process-idling
-- state from the AGENT'S log, and never from a clock. Ported from test-smoke-agent-watch.sh
-- (2360-psb8); same five arms.
--
--   1  classify: the pirria 2026-09-19 shape (a retried rate limit, then AI_RetryError
--      "Failed after 3 attempts", then only hourly `cleanup prune=7.days` ticks) is
--      state:agent-error-idle naming the RetryError line
--   2  NEGATIVE CONTROLS for classify: a working log, an error FOLLOWED by agent activity,
--      and a lone retrying AI_APICallError are state:working; an empty log is state:no-log
--   3  watch --log: the pirria shape yields, within grace + poll, exit 3, 04-agent-watch.txt
--      carrying refused:smoke-forge-lane:agent-dead-process-idling and the error line, and
--      04-opencode-agent.log copied host-side
--   4  NEGATIVE CONTROL for watch, the row's own: a log with an OLD terminal error that keeps
--      getting agent activity is never killed (it is still running when stopped)
--   5  watch --container through a fake podman: the newest log is read with two argv calls
--      (no shell string) and the container is STOPPED on the verdict
--
-- GRAMMAR ok:smoke-agent-watch:<n> arms | violation:smoke-agent-watch:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("smoke-agent-watch")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local S = ROOT .. "/scripts/smoke-agent-watch.sh"
if not fs.exists("scripts/smoke-agent-watch.sh") then T:refuse("subject-missing", "scripts/smoke-agent-watch.sh") end
local W = T:scratch()

local RETRY = "ERROR 2026-09-19T17:19:38 +2ms service=session.prompt error=AI_RetryError: Failed after 3 attempts. Last error: Rate limit exceeded. stream error"
local PIRRIA = table.concat({
    "INFO  2026-09-19T17:19:20 +0ms service=session id=ses_1 created",
    "INFO  2026-09-19T17:19:30 +5ms service=session.prompt step=1 tool=bash",
    "ERROR 2026-09-19T17:19:36 +3ms service=session.prompt error=AI_APICallError: Rate limit exceeded. Please try again later. stream error",
    RETRY,
    "INFO  2026-09-19T17:20:00 +0ms service=storage cleanup prune=7.days",
    "INFO  2026-09-19T18:20:00 +0ms service=storage cleanup prune=7.days",
    "INFO  2026-09-19T19:20:00 +0ms service=storage cleanup prune=7.days",
}, "\n") .. "\n"
fs.write(W.rel .. "/pirria.log", PIRRIA)
fs.write(W.rel .. "/working.log", "INFO  2026-09-28T10:00:00 +0ms service=session.prompt step=1 tool=read\nINFO  2026-09-28T10:00:05 +1ms service=session.prompt step=2 tool=bash\n")
fs.write(W.rel .. "/recovered.log", PIRRIA .. "INFO  2026-09-19T19:21:00 +4ms service=session.prompt step=2 tool=edit\n")
fs.write(W.rel .. "/retrying.log", "INFO  2026-09-28T10:00:00 +0ms service=session.prompt step=1\nERROR 2026-09-28T10:00:01 +3ms service=session.prompt error=AI_APICallError: Rate limit exceeded. stream error\n")
fs.write(W.rel .. "/empty.log", "")

local function classify(name)
    return ((T:run{ SH, S, "classify", W.abs .. "/" .. name, cwd = ROOT, timeout_ms = 30000 }.stdout or ""):gsub("\n$", ""))
end
local function lines(s)
    local t = {}
    for l in (s or ""):gmatch("[^\n]+") do t[l] = true end
    return t
end
local function read(rel) return fs.exists(rel) and fs.read(rel) or "" end

-- 1
local o1 = classify("pirria.log")
T:arm("1 the pirria shape is state:agent-error-idle naming the AI_RetryError line (housekeeping ticks ignored)",
    o1 == "state:agent-error-idle\t" .. RETRY, "[" .. o1 .. "]")

-- 2
local r2 = classify("working.log") .. "|" .. classify("recovered.log") .. "|" .. classify("retrying.log") .. "|" .. classify("empty.log")
T:arm("2 working, error-then-activity and a lone retrying APICallError are state:working; an empty log is state:no-log",
    r2 == "state:working|state:working|state:working|state:no-log", "[" .. r2 .. "]")

-- 3
local t0 = time.now_ms()
local r3 = T:run{ SH, S, "watch", "--log", W.abs .. "/pirria.log", "--grace", "2", "--poll", "1", "--out", W.abs .. "/out3",
    cwd = ROOT, timeout_ms = 30000 }
local dt = (time.now_ms() - t0) / 1000
local v3 = read(W.rel .. "/out3/04-agent-watch.txt")
T:arm("3 watch issues the named verdict within 10s (grace 2s), naming the error, with the agent log copied host-side",
    r3.code == 3 and dt <= 10 and lines(v3)["refused:smoke-forge-lane:agent-dead-process-idling"]
        and text.contains(v3, "error: " .. RETRY) and read(W.rel .. "/out3/04-opencode-agent.log") == PIRRIA,
    "rc=" .. tostring(r3.code) .. " dt=" .. dt .. "s [" .. v3 .. "]")

-- 4 — the row's negative control: an agent that keeps working after an old error.
fs.write(W.rel .. "/live.log", PIRRIA)
local writer = proc.spawn{ argv = { SH, "-s", "--", W.abs .. "/live.log" }, timeout_ms = 30000, stdin = [[
i=0; while [ "$i" -lt 12 ]; do
  echo "INFO  2026-09-19T19:3$i:00 +1ms service=session.prompt step=$i tool=bash" >>"$1"; i=$((i + 1)); sleep 0.5
done]] }
local watcher = proc.spawn{ argv = { SH, S, "watch", "--log", W.abs .. "/live.log", "--grace", "2", "--poll", "1", "--out", W.abs .. "/out4" },
    cwd = ROOT, timeout_ms = 30000 }
T:run{ "sleep", "6", timeout_ms = 10000 }
local verdict4 = read(W.rel .. "/out4/04-agent-watch.txt")
local w4 = watcher:kill()
writer:kill()
T:arm("4 a lane whose agent keeps working after an old terminal error is NOT killed (still watching after 6s, grace 2s)",
    verdict4 == "" and not (w4.status == "exited"), "watcher " .. tostring(w4.status) .. " code=" .. tostring(w4.code) .. " [" .. verdict4 .. "]")

-- 5 — the container path, through a fake podman that records its argv.
fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/podman", "#!/bin/sh\necho \"$*\" >> \"" .. W.abs .. "/podman-calls\"\n"
    .. "case \"$1 $3\" in\n  \"exec ls\") printf 'opencode-2026-09-19T171900.log\\nopencode-2026-09-18T090000.log\\n' ;;\n"
    .. "  \"exec cat\") cat \"" .. W.abs .. "/pirria.log\" ;;\nesac\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/bin/podman" }
local r5 = T:run{ SH, S, "watch", "--container", "tillandsias-x-forge", "--grace", "1", "--poll", "1", "--out", W.abs .. "/out5",
    cwd = ROOT, env = { PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin") }, timeout_ms = 30000 }
local calls = read(W.rel .. "/podman-calls")
local c = lines(calls)
T:arm("5 the container's NEWEST log is read by two argv calls and the forge container is stopped on the verdict",
    r5.code == 3 and c["exec tillandsias-x-forge ls -t /home/forge/.local/share/opencode/log"]
        and c["exec tillandsias-x-forge cat /home/forge/.local/share/opencode/log/opencode-2026-09-19T171900.log"]
        and c["stop tillandsias-x-forge"] and not text.contains(calls, "sh -c"),
    "rc=" .. tostring(r5.code) .. " calls=[" .. calls .. "]")

T:finish()
