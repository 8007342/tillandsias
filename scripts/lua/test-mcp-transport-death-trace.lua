-- @env PATH TMPDIR
-- @trace order:757-qwqz, spec:forge-environment-discoverability, order:2379-p5dq
--
-- test-mcp-transport-death-trace.lua — a stdio MCP server that dies mid-session appends its own record to
-- the expert health log: down/transport-died with a request in flight (or a set -e abort), stopped/
-- signal-idle when an idle one is ended. A clean EOF writes nothing. The guard alone (1-3), then the real
-- project-info and forge-plan over FIFOs (4-7). Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-mcp-transport-death-trace.lua
-- Verdict: ok:mcp-transport-death-trace:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("mcp-transport-death-trace")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local MCP = "images/default/config-overlay/mcp"
for _, f in ipairs{ "mcp-usage-log.sh", "project-info.sh", "forge-plan.sh" } do
    if not fs.exists(MCP .. "/" .. f) then T:refuse("subject-missing", f) end
end
-- The two states the mcp_outage: line counts; pinned against its reader below, so neither drifts alone.
local OUTAGE = '"state":"\\(down\\|absent\\)"'
local function outages(log) return select(2, log:gsub('"state":"down"', "")) + select(2, log:gsub('"state":"absent"', "")) end

local function environ(d)
    return { PATH = env.get("PATH"), HOME = d.abs, TMPDIR = env.get("TMPDIR"), TILLANDSIAS_EXPERT_HEALTH_LOG = d.abs .. "/health.jsonl",
        TILLANDSIAS_EXPERT_USAGE_LOG = d.abs .. "/usage.jsonl" }
end
local function health(d) return fs.exists(d.rel .. "/health.jsonl") and fs.read(d.rel .. "/health.jsonl") or "" end
local function has(log, ...)
    for _, s in ipairs{ ... } do if not text.contains(log, s) then return false end end
    return true
end

-- The guard alone, in a script that ends the way `body` says.
local function guard(tag, body, shared)
    local d = T:scratch(tag)
    local r = T:run{ SH, "-s", "--", shared or (ROOT .. "/" .. MCP .. "/mcp-usage-log.sh"), cwd = ROOT, env = environ(d), env_unset = { "TILLANDSIAS_*" },
        timeout_ms = 30000, stdin = 'cat > "$HOME/v.sh" <<\'V\'\nset -euo pipefail\n. "$1"\n' .. body .. '\nV\nexec "$BASH" "$HOME/v.sh" "$1"\n' }
    return health(d), r.code, health(d) .. " rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 200)
end
local INFLIGHT = 'mcp_transport_guard fixture-inflight\nmcp_tg_inflight read_file\nkill -TERM $$\nsleep 5'
local CLEAN = "mcp_transport_guard fixture-clean\nmcp_tg_inflight read_file\nmcp_tg_done\nmcp_tg_clean_shutdown\nexit 0"
local log, rc, got = guard("v1", INFLIGHT)
T:arm("1 a signal with a request in flight is down, naming the signal and the tool", has(log, '"server":"fixture-inflight"', '"state":"down"',
    '"stage":"transport-died"', '"signal":"TERM"', '"last_tool":"read_file"'), got)
T:arm("1 and it carries the advice", has(log, '"advice":"filesystem-reads-sanctioned-for-rest-of-cycle"'), got)
log, rc, got = guard("v2", "mcp_transport_guard fixture-abort\nmcp_tg_inflight grep_code\nfalse")
T:arm("2 a set -e abort is down with its rc", has(log, '"server":"fixture-abort"', '"state":"down"', '"rc":1'), got)
log, rc, got = guard("v3", CLEAN)
T:arm("3 CONTROL a clean shutdown writes nothing", log == "" and rc == 0, got)

local d = T:scratch("v4")
local r = T:run{ SH, ROOT .. "/" .. MCP .. "/project-info.sh", cwd = ROOT, env = environ(d), env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
    stdin = '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
        .. '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_type","arguments":{"path":"."}}}\n' }
T:arm("4 CONTROL a full session ended by EOF is answered and writes nothing", r.code == 0 and text.contains(r.stdout or "", '"id":2') and health(d) == "",
    health(d) .. " rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 200))

-- A real server on FIFOs, held by this shell. `exec env` makes $! the server itself: a wrapper subshell
-- would take the TERM and the server never see it. $4: term (end it idle) | vanish (close its stdout mid-write).
local FIFO = [[
cd "$1" || exit 96
mkfifo "$2/in" "$2/out" || exit 95
seq 1 60000 > "$2/big.txt"
(exec env "$BASH" "$3" < "$2/in" > "$2/out" 2>/dev/null) &
pid=$!
trap 'kill -9 "$pid" 2>/dev/null' EXIT
exec 7>"$2/in" 8<"$2/out"
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n' >&7
IFS= read -t 30 -r _ <&8 || exit 94
if [ "$4" = vanish ]; then
    printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"%s"}}}\n' "$2/big.txt" >&7
    sleep 2
    exec 8<&- 7>&-
else
    kill -TERM "$pid"
fi
wait "$pid"
pid=
exit 0
]]
local function server(tag, name, how)
    local s = T:scratch(tag)
    local x = T:run{ SH, "-s", "--", ROOT, s.abs, name:find("/", 1, true) and name or (ROOT .. "/" .. MCP .. "/" .. name), how, stdin = FIFO, env = environ(s),
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 90000 }
    local l = health(s)
    return l, l .. " rc=" .. tostring(x.code) .. " " .. (x.stderr or ""):sub(1, 200)
end
log, got = server("v5", "project-info.sh", "term")
T:arm("5 project-info ended while idle is stopped/signal-idle", has(log, '"server":"project-info"', '"state":"stopped"', '"stage":"signal-idle"'), got)
T:arm("5 and it is not counted as an outage", log ~= "" and outages(log) == 0, got)
log, got = server("v6", "project-info.sh", "vanish")
T:arm("6 a client that vanishes mid-write leaves down/transport-died naming read_file", has(log, '"server":"project-info"', '"state":"down"',
    '"stage":"transport-died"', '"last_tool":"read_file"'), got)
T:arm("6 and it is counted as an outage", outages(log) >= 1, got)
log, got = server("v7", "forge-plan.sh", "term")
T:arm("7 forge-plan arms the same guard", has(log, '"server":"forge-plan"', '"state":"stopped"'), got)
T:arm("8 the report's outage count reads the two states these arms count", text.contains(fs.read("scripts/cycle-metrics.sh"), OUTAGE), "pattern gone")

-- MUTATION. A server finds its siblings by its own path, so the mutant guard sits in a scratch copy of the dir.
local M = T:scratch("mutant")
T:must{ SH, "-s", "--", ROOT .. "/" .. MCP, M.abs, stdin = 'cp -R "$1/." "$2/"\n' }
local src = fs.read(MCP .. "/mcp-usage-log.sh"):gsub("\r\n", "\n")
local function mutant(from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    fs.write(M.rel .. "/mcp-usage-log.sh", src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return M.abs .. "/mcp-usage-log.sh"
end
log, rc, got = guard("m1", INFLIGHT, mutant("trap '_mcp_tg_exit $?' EXIT", ":"))
T:arm("9 MUTATION an unarmed guard leaves no trace, and fails arm 1", log == "" and rc ~= 0, got)
log, rc, got = guard("m2", CLEAN, mutant("    _mcp_tg_clean=1\n", "    :\n"))
T:arm("9 MUTATION a shutdown the guard does not know fails arm 3", has(log, '"server":"fixture-clean"'), got)
mutant('_mcp_tg_record "stopped" "signal-idle"', '_mcp_tg_record "down" "signal-idle"')
log, got = server("m3", M.abs .. "/project-info.sh", "term")
T:arm("9 MUTATION an idle end recorded as down fails arm 5", outages(log) == 1, got)

T:finish()
