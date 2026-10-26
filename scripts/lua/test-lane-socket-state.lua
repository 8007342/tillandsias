-- @trace spec:mcp-tool-socket, order:1863-eckw
-- @env PATH
--
-- test-lane-socket-state.lua — the forge names a stale lane socket (1863-eckw).
--
-- lane_socket_state (images/default/lib-common.sh) reports the lane MCP socket
-- at $TILLANDSIAS_CONTROL_SOCKET as one of four states, and the startup
-- context and the host-browser bridge print it, so a dead lane is named
-- instead of surfacing as a bare ECONNREFUSED:
--   1 READY   a socket with a listener
--   2 STALE   a socket file with NO listener (the field state of 1863-eckw:
--             the launcher that bound it had exited)
--   3 ABSENT  no socket file — NEGATIVE CONTROL: a missing socket is not
--             called stale
--   4 UNSET   no TILLANDSIAS_CONTROL_SOCKET at all
-- The function is cut from lib-common.sh and run by bash under each socket.
-- The stale socket is made the way the field made it: bound, hard-linked,
-- and the listener closed, which unlinks the bound name and leaves the link
-- as a socket inode nothing accepts on.
--
-- Usage: tillandsias-plan script run scripts/lua/test-lane-socket-state.lua

local LIB = "images/default/lib-common.sh"
local lib = fs.read(LIB)
if not lib then
    verdict.emit("violation:lane-socket-state:no-subject", 1, LIB .. " does not exist")
end
local fn = lib:match("\nlane_socket_state%(%) {\n.-\n}\n")
if not fn then
    verdict.emit("violation:lane-socket-state:no-function", 1, "lane_socket_state() not found in " .. LIB)
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("lane-socket-state", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/lss" .. tostring(math.random(1000, 9999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name .. (got and (" — " .. got) or ""))
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function state(sock)
    local envt = { PATH = env.get("PATH") or "/usr/bin:/bin" }
    if sock then envt.TILLANDSIAS_CONTROL_SOCKET = sock end
    local r = proc.run({ argv = { "bash", "-s" }, stdin = fn .. "lane_socket_state\n", env = envt, timeout_ms = 10000 })
    return text.trim(r.stdout or "")
end

local ok_live, live = pcall(fs.listen_unix, REL .. "/l.s")
if not ok_live then
    if tostring(live):find("unsupported", 1, true) then
        verdict.ok("lane-socket-state", "skip: this runtime cannot create unix sockets")
    end
    verdict.emit("violation:lane-socket-state:no-fixture-socket", 1, tostring(live))
end
local got = state(DIR .. "/l.s")
arm("1 READY a socket with a listener", got == "ready", got)

local ok_b, bound = pcall(fs.listen_unix, REL .. "/b.s")
local ln = proc.run({ argv = { "ln", DIR .. "/b.s", DIR .. "/s.s" }, timeout_ms = 10000 })
if ok_b then bound:close() end
if ok_b and ln.code == 0 and not fs.exists(REL .. "/b.s") then
    got = state(DIR .. "/s.s")
    arm("2 STALE a socket file nothing accepts on", got == "stale", got)
else
    arm("2 STALE fixture: a listenerless socket inode", false, "could not make one (ln rc=" .. tostring(ln.code) .. ")")
end

got = state(DIR .. "/m.s")
arm("3 ABSENT a missing socket is not called stale", got == "absent", got)
got = state(nil)
arm("4 UNSET no TILLANDSIAS_CONTROL_SOCKET", got == "unset", got)

live:close()
proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:lane-socket-state:" .. #failed .. "-failed", 1)
end
verdict.ok("lane-socket-state", passed .. " arms")
