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
--   8 STALE     a lane that ANSWERS but which the tray marked lane-stale (an
--               older launcher still serves it, 2070-mtf9) is failed as
--               host_lane=stale-build, naming the serving pid and the remedy
--   9 HELP      --help prints the usage block, rc 0; an unknown argument is rc 2
--  10 TEXT      without --json each row is one padded line, and the exit is 1
--  11 QUOTING   an MCP command, a project name and a socket path holding a
--               quote and a ; reach the shell as data: nothing they name runs
-- Red before 1874-6p63: there is no tillandsias-doctor.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-doctor.lua

local DOCTOR = "images/default/cli/tillandsias-doctor"
if not fs.exists(DOCTOR) then
    verdict.emit("violation:tillandsias-doctor:no-subject", 1, DOCTOR .. " does not exist (1874-6p63)")
end

-- The forge runs the command with its own lua (2389-8rmy); a host has none, so
-- it is loaded here with io.popen and os answered by this fixture: every shell
-- line it builds still runs for real, under the env the case sets.
local function run_doctor(e, ...)
    local so, se, stop = {}, {}, {}
    local function sink(t) return { write = function(self, ...) for _, v in ipairs({ ... }) do t[#t + 1] = v end return self end } end
    local world = { string = string, table = table, math = math, ipairs = ipairs, pairs = pairs, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        arg = { [0] = "/usr/local/bin/tillandsias-doctor", ... },
        io = { stdout = sink(so), stderr = sink(se), popen = function(c)
            -- The command line goes to a shell on stdin: the runtime refuses `sh -c <string>`.
            local r = proc.run({ argv = { "bash", "-s" }, stdin = c .. "\n", env = e, timeout_ms = 120000 })
            local s = r.stdout or ""
            return { read = function() local x = s; s = ""; return x end,
                close = function() return r.code == 0 or nil, "exit", r.code end }
        end },
        os = { getenv = function(n) return e[n] end, exit = function(c) stop.code = c; error(stop) end } }
    local f, why = load((fs.read(DOCTOR):gsub("^#![^\n]*", "")), "=tillandsias-doctor", "t", world)
    if not f then return { stdout = "", stderr = tostring(why), code = "load" } end
    local ok, got = pcall(f)
    if not ok and got ~= stop then return { stdout = table.concat(so), stderr = tostring(got), code = "error" } end
    return { stdout = table.concat(so), stderr = table.concat(se), code = stop.code or 0 }
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

local r = run_doctor({
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
}, "--json")

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

-- 2070-mtf9: a live listener plus the tray's lane-stale marker beside it.
fs.mkdir(REL .. "/live")
local ok_l, live = pcall(fs.listen_unix, REL .. "/live/m.s")
if ok_l then
    fs.write(REL .. "/live/lane-stale",
        "warn:lane-stale:doctor-smoke-default: runs 56.11.9.1+bbbb, installed 56.11.10.1+aaaa; relaunch that forge to use the installed build; served by pid 1020477 (exe deleted)\n")
    local r2 = run_doctor({
            PATH = DIR .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
            HOME = DIR,
            TILLANDSIAS_PROJECT = "doctor-smoke",
            TILLANDSIAS_CONTROL_SOCKET = DIR .. "/live/m.s",
            TILLANDSIAS_DOCTOR_LIB_DIR = ROOT .. "/images/default",
            TILLANDSIAS_DOCTOR_MCP_CONFIG = DIR .. "/none.json",
            TILLANDSIAS_DOCTOR_CHEATSHEETS = DIR .. "/sheets",
            TILLANDSIAS_DOCTOR_SRC_DIR = DIR,
            TILLANDSIAS_DOCTOR_CACHE_DIR = DIR,
            TILLANDSIAS_DOCTOR_PROBE_SECS = "3",
    }, "--json")
    live:close()
    local ok2, rep2 = pcall(json.parse, r2.stdout or "")
    local lane2
    if ok2 and type(rep2) == "table" then
        for _, c in ipairs(rep2.checks or {}) do if c.name == "lane" then lane2 = c end end
    end
    arm("8 STALE a lane an older launcher still serves is failed as host_lane=stale-build with its pid",
        lane2 and lane2.status == "failed"
            and lane2.detail:find("host_lane=stale-build", 1, true) ~= nil
            and lane2.detail:find("pid 1020477", 1, true) ~= nil
            and lane2.detail:find("relaunch", 1, true) ~= nil,
        show(lane2))
else
    arm("8 STALE a live fixture socket could be bound", false, tostring(live))
end

local function base(extra)
    local e = {
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
    }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

local h = run_doctor(base(), "--help")
local u = run_doctor(base(), "--bogus")
arm("9 HELP --help prints the usage, rc 0; an unknown argument is rc 2 with nothing on stdout",
    h.code == 0 and h.stdout:find("^tillandsias%-doctor — one command") and h.stdout:find("\nUsage: tillandsias-doctor [--json]\n\nExit 0", 1, true)
        and u.code == 2 and u.stdout == "" and u.stderr:find("unknown arg '--bogus'", 1, true),
    h.code .. " " .. h.stdout .. " / " .. u.code .. " " .. u.stderr)

local t = run_doctor(base())
arm("10 TEXT each row is one padded line, exit 1",
    t.code == 1 and t.stdout:find("^lane               failed  host_lane=stale: ")
        and t.stdout:find("\nmcp:good           ok      initialize answered\n", 1, true)
        and t.stdout:find("\nrenderer           info    no in-forge renderer", 1, true),
    t.code .. " " .. t.stdout .. t.stderr)

fs.write(REL .. "/bin/touched", "#!/bin/sh\n: > '" .. DIR .. "/pwned'\n")
proc.run({ argv = { "chmod", "+x", DIR .. "/bin/touched" }, timeout_ms = 10000 })
local Q = "x'; touched; '"
fs.write(REL .. "/evil.json", json.encode({ mcp = {
    [Q] = { type = "local", command = { Q } },
    good = { type = "local", command = { DIR .. "/bin/good-mcp", Q, "$(touched)" } },
} }))
local ev = run_doctor(base({ TILLANDSIAS_PROJECT = Q .. "$(touched)", TILLANDSIAS_DOCTOR_MCP_CONFIG = DIR .. "/evil.json",
    TILLANDSIAS_DOCTOR_CHEATSHEETS = DIR .. "/" .. Q, TILLANDSIAS_DOCTOR_PROBE_SECS = "3" .. Q }), "--json")
local ok_e, rep_e = pcall(json.parse, ev.stdout or "")
local named = false
if ok_e and type(rep_e) == "table" then
    for _, c in ipairs(rep_e.checks or {}) do
        if c.name == "mcp:" .. Q and c.status == "failed" and c.detail == "command not found: " .. Q then named = true end
    end
end
arm("11 QUOTING a quote and a ; in a server, an argument, a project and a path run nothing",
    not fs.exists(REL .. "/pwned") and named, (fs.exists(REL .. "/pwned") and "touched RAN " or "") .. (ev.stdout or "") .. (ev.stderr or ""))

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-doctor:" .. #failed .. "-failed", 1)
end
verdict.ok("tillandsias-doctor", passed .. " arms")
