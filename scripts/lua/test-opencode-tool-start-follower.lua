-- @trace order:1385-h6uz, order:2233-vxu9
--
-- Pins images/default/opencode-tool-start-follower.sh: the prompted opencode
-- lane announces each tool call when it STARTS, from opencode's own log,
-- because `opencode run` prints a call only when it completes (a three-hour
-- silent macOS smoke lane was one long call). Hermetic: a scratch log stands
-- in for opencode's. Ported from test-opencode-tool-start-follower.sh
-- (2233-vxu9): the follower runs under proc.spawn (its own process group, so
-- killing it takes its `tail -F` with it; a pkill on the scratch path stays as
-- a second net), with its output redirected to a file the arms poll.
--
--   1 a new bash call is announced with its command
--   2 an unquoted pattern is announced
--   3 history before the follower started is not replayed
--   4 unrelated log lines are not echoed
--   5 FAIL-LOUD: a log that never appears is named, rc 3, not silence
--   6 the prompted branch starts the follower before its exec
--   7 the forge image installs the follower and marks it executable
--
-- Verdict: ok:opencode-tool-start-follower:<pass>/<total>
--        | refused:opencode-tool-start-follower:<pass>/<total>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local FOLLOW = root .. "/images/default/opencode-tool-start-follower.sh"
local ENTRY = "images/default/entrypoint-forge-opencode.sh"
local IMAGE = "images/default/Containerfile"
local pass, failn = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/opencode-follower-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local LOG = W .. "/opencode.log"
local function append(line) proc.run{ argv = { "bash", W .. "/append.sh", LOG, line } } end
fs.write(rel .. "/append.sh", "printf '%s\\n' \"$2\" >> \"$1\"\n")
fs.write(rel .. "/follow.sh", "exec bash \"$1\" \"$2\" \"$3\" > \"$4\" 2>&1\n")
local function pause(s) proc.run{ argv = { "sleep", s } } end

append('timestamp=OLD level=INFO message=evaluated permission=bash pattern="history-from-an-earlier-run" action.permission=*')
local F = proc.spawn{ argv = { "bash", W .. "/follow.sh", FOLLOW, LOG, "5", W .. "/out" }, timeout_ms = 120000 }
local function stop()
    if F then F:kill(); F = nil end
    proc.run{ argv = { "pkill", "-f", "tail -n 0 -F " .. W .. "/" } }
end
pause("1")
append('timestamp=2026-09-26T13:39:50.047Z level=INFO run=x message=evaluated permission=bash pattern="sleep 5" action.permission=* action.action=allow action.pattern=*')
append('timestamp=T level=INFO message="an unrelated log line"')
append('timestamp=T level=INFO message=evaluated permission=edit pattern=src/main.rs action.permission=*')
local function seen() return fs.exists(rel .. "/out") and fs.read(rel .. "/out") or "" end
for _ = 1, 10 do
    if seen():find("src/main.rs", 1, true) then break end
    pause("0.3")
end
local o = seen()
stop()

-- 1-4
if o:find("[forge] tool start: bash: sleep 5", 1, true) then ok("a new bash call is announced with its command")
else bad("no announcement for 'sleep 5': " .. o) end
if o:find("[forge] tool start: edit: src/main.rs", 1, true) then ok("an unquoted pattern is announced")
else bad("unquoted pattern missing: " .. o) end
if o:find("history-from-an-earlier-run", 1, true) then bad("replayed history from before it started: " .. o)
else ok("history before the follower started is not replayed") end
if o:find("unrelated log line", 1, true) then bad("echoed an unrelated line: " .. o)
else ok("unrelated log lines are not echoed") end

-- 5 FAIL-LOUD
local a = proc.run{ argv = { "bash", FOLLOW, W .. "/never.log", "1" }, timeout_ms = 60000 }
local absent = (a.stdout or "") .. (a.stderr or "")
if a.code == 3 and absent:find("opencode log never appeared", 1, true) then
    ok("a log that never appears is reported loudly (rc 3)")
else
    bad("absent log was not loud: rc=" .. tostring(a.code) .. " out=" .. absent)
end

-- 6 wiring: the prompted branch starts the follower BEFORE its exec, and the
-- image installs and marks it executable.
local branch, inside = {}, false
for _, l in ipairs(text.lines(fs.read(ENTRY))) do
    if not inside and l:find('TILLANDSIAS_OPENCODE_PROMPT:-}" ]; then', 1, true) then inside = true end
    if inside then
        branch[#branch + 1] = l
        if l:find("exec /usr/local/bin/harness-supervisor", 1, true) then break end
    end
end
if table.concat(branch, "\n"):find("opencode-tool-start-follower &", 1, true) then
    ok("the prompted branch starts the follower before exec")
else
    bad("the prompted branch does not start the follower before exec")
end
local img = fs.read(IMAGE)
if ("\n" .. img):find("\nCOPY opencode-tool-start-follower.sh /usr/local/bin/opencode-tool-start-follower\n", 1, true)
    and img:find("/usr/local/bin/opencode-tool-start-follower \\", 1, true) then
    ok("the forge image installs the follower and marks it executable")
else
    bad("the forge image does not COPY and chmod the follower")
end

stop()
proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 }
local total = pass + failn
if failn == 0 then verdict.ok("opencode-tool-start-follower:" .. pass .. "/" .. total) end
verdict.emit("refused:opencode-tool-start-follower:" .. pass .. "/" .. total, 1)
