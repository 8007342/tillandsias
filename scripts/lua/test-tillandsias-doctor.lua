-- @trace spec:forge-environment-discoverability, spec:mcp-tool-socket, order:1874-6p63
-- @env PATH
--
-- test-tillandsias-doctor.lua — one in-forge command reports every lane and
-- MCP fault with its reason (1874-6p63).
--
-- images/default/cli/tillandsias-doctor runs outside the image through its env
-- seams, against a DEAD lane socket (a socket inode nothing accepts on, the
-- 1863-eckw field state), an MCP config holding the real host-browser bridge
-- and a stub server that answers initialize, a curl that cannot reach the
-- router and a flutter shim that exits 69:
--   1 JSON      --json prints one object with a checks array and ok=false
--   2 LANE      the lane row is failed and names host_lane=stale
--   3 BRIDGE    the host-browser MCP row is failed with a reason
--   4 CONTROL   NEGATIVE CONTROL: the stub MCP server is ok, so a failed row
--               is the doctor's verdict, not a doctor that fails everything
--   5 RENDERER  the no-in-forge-renderer line is present
--   6 ROUTER    both router rows (direct, via-proxy) are failed with a reason
--   7 CONTEXT   the forge startup context names tillandsias-doctor
-- Red before 1874-6p63: there is no tillandsias-doctor.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-doctor.lua

local DOCTOR = "images/default/cli/tillandsias-doctor"
if not fs.exists(DOCTOR) then
    verdict.emit("violation:tillandsias-doctor:no-subject", 1, DOCTOR .. " does not exist (1874-6p63)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("tillandsias-doctor", "git rev-parse --show-toplevel did not answer")
end
-- Short: the stale socket's path must fit AF_UNIX.
local REL = "target/plan-scratch/dr" .. tostring(math.random(1000, 9999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL

local failed, passed = {}, 0
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name .. (got and (" — " .. got) or ""))
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- The dead lane: bind, hard-link, close. Closing unlinks the bound name and
-- leaves the link a socket inode with no listener.
local ok_b, bound = pcall(fs.listen_unix, REL .. "/b.s")
if not ok_b then
    if tostring(bound):find("unsupported", 1, true) then
        verdict.ok("tillandsias-doctor", "skip: this runtime cannot create unix sockets")
    end
    verdict.emit("violation:tillandsias-doctor:no-fixture-socket", 1, tostring(bound))
end
proc.run({ argv = { "ln", DIR .. "/b.s", DIR .. "/s.s" }, timeout_ms = 10000 })
bound:close()

fs.mkdir(REL .. "/bin")
fs.mkdir(REL .. "/sheets")
fs.write(REL .. "/sheets/one.md", "# a cheatsheet\n")
-- The stub fakes an unreachable router; the lane probe (--unix-socket) goes to
-- the real curl so the lane's state is measured, not stubbed.
-- The stub is first on PATH; for --unix-socket it drops itself and runs the real curl.
fs.write(REL .. "/bin/curl", "#!/bin/sh\ncase \"$*\" in *--unix-socket*) PATH=\"${PATH#*:}\" exec curl \"$@\" ;; esac\n" ..
    "echo 'curl: (6) Could not resolve host: router' >&2\nexit 6\n")
fs.write(REL .. "/bin/flutter", "#!/bin/sh\necho 'host_lane=stale: the host toolchain service is not reachable' >&2\nexit 69\n")
fs.write(REL .. "/bin/good-mcp", "#!/bin/sh\nread -r _\necho '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'\n")
proc.run({ argv = { "chmod", "+x", DIR .. "/bin/curl", DIR .. "/bin/flutter", DIR .. "/bin/good-mcp" }, timeout_ms = 10000 })
fs.write(REL .. "/config.json", json.encode({
    mcp = {
        ["host-browser"] = { type = "local", command = { "bash", ROOT .. "/images/default/config-overlay/mcp/host-browser.sh" } },
        good = { type = "local", command = { DIR .. "/bin/good-mcp" } },
    },
}))

local r = proc.run({
    argv = { "bash", ROOT .. "/" .. DOCTOR, "--json" },
    env = {
        PATH = DIR .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        HOME = DIR,
        TILLANDSIAS_PROJECT = "doctor-smoke",
        TILLANDSIAS_CONTROL_SOCKET = DIR .. "/s.s",
        TILLANDSIAS_DOCTOR_LIB_DIR = ROOT .. "/images/default",
        TILLANDSIAS_DOCTOR_MCP_CONFIG = DIR .. "/config.json",
        TILLANDSIAS_DOCTOR_CHEATSHEETS = DIR .. "/sheets",
        TILLANDSIAS_DOCTOR_SRC_DIR = DIR,
        TILLANDSIAS_DOCTOR_CACHE_DIR = DIR,
        TILLANDSIAS_DOCTOR_PROBE_SECS = "3",
    },
    timeout_ms = 120000,
})

local ok_p, report = pcall(json.parse, r.stdout or "")
arm("1 JSON --json prints one object, ok=false, exit 1",
    ok_p and type(report) == "table" and report.ok == false and r.code == 1,
    (r.stdout or "") .. " rc=" .. tostring(r.code) .. " " .. (r.stderr or ""))
local by = {}
if ok_p and type(report) == "table" then
    for _, c in ipairs(report.checks or {}) do by[c.name] = c end
end
local function show(c) return c and (c.status .. ": " .. c.detail) or "no row" end

local lane = by["lane"]
arm("2 LANE the lane row is failed and names host_lane=stale",
    lane and lane.status == "failed" and lane.detail:find("host_lane=stale", 1, true) ~= nil, show(lane))
local hb = by["mcp:host-browser"]
-- The real bridge, run on the dead socket, answers initialize with its own
-- error naming the stale lane (1863-eckw): the row carries the bridge's words.
arm("3 BRIDGE the host-browser MCP row is failed with the bridge's own reason",
    hb and hb.status == "failed" and hb.detail:find("host_lane=stale", 1, true) ~= nil, show(hb))
local good = by["mcp:good"]
arm("4 CONTROL a server that answers initialize is ok", good and good.status == "ok", show(good))
local rend = by["renderer"]
arm("5 RENDERER the no-in-forge-renderer line is present",
    rend and rend.detail:find("no in-forge renderer", 1, true) ~= nil, show(rend))
local direct, proxied = by["router:direct"], by["router:via-proxy"]
arm("6 ROUTER both router rows are failed with a reason",
    direct and proxied and direct.status == "failed" and proxied.status == "failed"
        and #direct.detail > 0 and #proxied.detail > 0,
    show(direct) .. " / " .. show(proxied))

local lib = fs.read("images/default/lib-common.sh") or ""
local ctx = lib:match("inject_startup_context%(%) {.-\n}\n") or ""
arm("7 CONTEXT the forge startup context names tillandsias-doctor",
    ctx:find("tillandsias-doctor", 1, true) ~= nil, #ctx > 0 and "inject_startup_context found" or "no inject_startup_context")

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-doctor:" .. #failed .. "-failed", 1)
end
verdict.ok("tillandsias-doctor", passed .. " arms")
