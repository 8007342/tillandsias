-- @trace spec:forge-environment-discoverability, order:2207-vswc
--
-- test-mcp-server-resilience.lua — PORTED from test-mcp-server-resilience.sh
-- (2207-vswc), same modes, same verdict lines. Request-fault ISOLATION for
-- the stdio MCP expert servers: a fault in ONE request (a SIGPIPE'd pipeline,
-- a malformed JSON line) must fail THAT request at worst — never the server.
-- 2026-08-15 the exact opposite shipped live: a read_file(offset,limit) whose
-- `tail | head` took SIGPIPE under `set -euo pipefail` killed project-info
-- mid-session, the client saw "MCP error -32000: Connection closed", and every
-- project-info tool deregistered for the rest of the session.
--
-- Usage: script run scripts/lua/test-mcp-server-resilience.lua sigpipe|malformed
-- The servers run from the checkout (cwd), stdin fed by the runner.
--
-- GRAMMAR (the verdict, last line):
--   ok:project-info-survives-sigpipe
--   ok:mcp-servers-survive-malformed-line
--   fail:<detail>   (exit 1)

local PROJECT_INFO = "images/default/config-overlay/mcp/project-info.sh"
local FORGE_PLAN = "images/default/config-overlay/mcp/forge-plan.sh"
local MODE = arg[1] or ""

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/mcp-resilience-" .. tostring(time.now_ms())
local WORK = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", WORK } }
local function cleanup() proc.run{ argv = { "find", WORK, "-delete" }, timeout_ms = 60000 } end
local function fail(d) cleanup(); verdict.emit("fail:" .. d, 1) end

local function serve(server, requests)
    return proc.run{ argv = { "bash", server }, stdin = requests, timeout_ms = 120000 }
end

if MODE == "sigpipe" then
    -- A fixture long enough that `tail -n +100 | head -n 5` leaves tail tens
    -- of thousands of lines still to write when head exits — the
    -- guaranteed-SIGPIPE window that killed the live server.
    local big = {}
    for i = 1, 40000 do big[i] = tostring(i) end
    fs.write(rel .. "/big.txt", table.concat(big, "\n") .. "\n")
    local req = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"'
        .. WORK .. '/big.txt","offset":100,"limit":5}}}\n'
        .. '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_type","arguments":{"path":"."}}}\n'
    local r = serve(PROJECT_INFO, req)
    if r.code ~= 0 then fail("server-died-rc-" .. tostring(r.code)) end
    local o = r.stdout or ""
    if not o:find('"id":1', 1, true) then fail("first-request-unanswered") end
    if not o:find('"id":2', 1, true) then fail("followup-request-unanswered") end
    cleanup()
    verdict.emit("ok:project-info-survives-sigpipe", 0)
elseif MODE == "malformed" then
    local req = 'this is not json\n{"jsonrpc":"2.0","id":7,"method":"tools/list"}\n'
    for _, server in ipairs({ PROJECT_INFO, FORGE_PLAN }) do
        local base = server:match("([^/]+)$")
        local r = serve(server, req)
        if r.code ~= 0 then fail(base .. "-died-on-malformed-line-rc-" .. tostring(r.code)) end
        if not (r.stdout or ""):find('"id":7', 1, true) then fail(base .. "-no-reply-after-malformed-line") end
    end
    cleanup()
    verdict.emit("ok:mcp-servers-survive-malformed-line", 0)
end
fail("usage-sigpipe-or-malformed")
