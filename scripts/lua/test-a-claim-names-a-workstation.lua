-- @env PATH HOME
-- @trace order:1201-hsf9, order:772-4se9, order:2372-snfs
--
-- test-a-claim-names-a-workstation.lua — `set-field <row> status in_progress` without --host is
-- refused: the default host is the compiled platform, so every host on one platform would claim
-- under one name. Ported from the .sh of the same name (2372-snfs). Scratch ledgers only.
--
--   1 refused with the typed verdict      2 and no fragment is written
--   3 CONTROL --host <workstation>, 4 CONTROL --host <the platform>, both accepted
--   5 CONTROL completed, ready and a non-status field keep the default host
--   6 772-4se9's writer_host_default unit test is run by cargo, not read
--
-- Usage: tillandsias-plan script run scripts/lua/test-a-claim-names-a-workstation.lua
-- Verdict: ok:a-claim-names-a-workstation:<n> arms | violation:... | skip:...:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("a-claim-names-a-workstation")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local function ledger()
    local d = T:scratch()
    fs.mkdir(d.rel .. "/plan/index.d")
    fs.write(d.rel .. "/plan/index.yaml", [[
packets:
  - packet_id: a-fixture-row
    order: 1-aaaa
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: a row to claim
    unscoreable: "fixture packet; not scored"
    events: []
]])
    return d
end
local function set(...)
    local d = ledger()
    local argv = { PLAN, "--index", d.abs .. "/plan/index.yaml", "set-field", "1-aaaa", ... }
    local r = proc.run{ argv = argv, cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local n = #fs.list(d.rel .. "/plan/index.d")
    local o = (r.stdout or "") .. (r.stderr or "")
    return { rc = r.code, out = o, n = n, why = "rc=" .. tostring(r.code) .. " fragments=" .. n .. " " .. o:sub(1, 300) }
end
local x = set("status", "in_progress", "--reason", "claimed with no host")
T:arm("1 a claim with no --host is refused, with the typed verdict", x.rc ~= nil and x.rc ~= 0 and text.contains(x.out, "refused:set-field:claim-without-a-host"), x.why)
T:arm("2 and it wrote no fragment", x.n == 0, x.why)
x = set("status", "in_progress", "--host", "macuahuitl", "--reason", "claimed with a host")
T:arm("3 CONTROL an explicit --host is accepted and writes its fragment", x.rc == 0 and x.n == 1, x.why)
local sys = text.trim(T:run{ "uname", "-s" }.stdout or ""):lower()
local platform = sys == "darwin" and "macos" or (sys:match("^mingw") or sys:match("^msys") or sys:match("^cygwin")) and "windows" or sys
x = set("status", "in_progress", "--host", platform, "--reason", "I really do mean the platform")
T:arm("4 CONTROL so is the platform, when it is named", x.rc == 0 and x.n == 1, platform .. " " .. x.why)
for _, c in ipairs{ { "status", "completed", "--evidence", "fixture-evidence" }, { "status", "ready", "--reason", "released-with-no-host" }, { "priority", "p1", "--reason", "a-non-status-field" } } do
    x = set(table.unpack(c))
    T:arm("5 CONTROL " .. c[1] .. " " .. c[2] .. " still defaults its host", x.rc == 0, x.why)
end
local cargo = fixture.which("cargo") and { "cargo" }
if not cargo and fixture.which("toolbox") then cargo = { "toolbox", "run", "cargo" } end
if not cargo then
    out.line("skip: 6 no cargo on this host; the unit test is owed a run elsewhere")
else
    local function unit(incremental)
        local argv = {}
        for i, a in ipairs(cargo) do argv[i] = a end
        for _, a in ipairs{ "test", "-p", "tillandsias-plan", "writer_host_default_is_the_compiled_platform" } do argv[#argv + 1] = a end
        local r = proc.run{ argv = argv, cwd = ROOT, env = incremental and { CARGO_INCREMENTAL = "0" } or nil, timeout_ms = 280000 }
        return r.code, (r.stdout or "") .. (r.stderr or "")
    end
    local rc, o = unit()
    -- 1803-pcap: a link failure on the incremental cache is retried once without it.
    if rc ~= 0 and text.contains(o, "linking with `cc` failed") then
        out.line("note: 6 link failure on the incremental cache; retrying once without it")
        rc, o = unit(true)
    end
    if rc ~= 0 and text.contains(o, "linker `cc` not found") then
        out.line("skip: 6 no linker here (a bare host); the unit test runs in the toolbox")
        T:finish()
    end
    if rc ~= 0 then
        for l in (T:run{ "df", "-Pk", ROOT .. "/target" }.stdout or ""):gmatch("[^\n]+") do out.line("  6 disk: " .. l) end
    end
    T:arm("6 772-4se9's unit test passes, executed", rc == 0 and text.contains(o, "1 passed"), "rc=" .. tostring(rc) .. " " .. o:sub(-900))
end
T:finish()
