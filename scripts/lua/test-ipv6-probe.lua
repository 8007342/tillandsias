-- @env PATH HOME
-- @trace order:1548-mhyk, spec:init-command, order:2080-zcur
--
-- test-ipv6-probe.lua — prove the --init IPv6 probe (a) parses its address list
-- and (b) probes EVERY default router, declaring IPv6 functional only when all
-- carry traffic. Hermetic: the probe core takes an injected route table and an
-- injected per-router probe; nothing here touches containers.conf or the network.
--
-- Arms (each is a named cargo unit test in tillandsias-headless; an arm that
-- ran zero tests is a false green, so each demands "1 passed"):
--   parse, one-blackhole, both-ok, no-router, flowlabel, unmeasured
--
-- Pinned by litmus:ipv6-probe-per-router-shape.
-- Ported from scripts/test-ipv6-probe.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-ipv6-probe.lua
-- Verdict: ok:ipv6-probe:<n> arms | violation:ipv6-probe:<n>-failed | skip:ipv6-probe:linux-only-unit-tests:<uname>

local fixture = require "common.fixture"
local T = fixture.new("ipv6-probe")
local ROOT = fixture.repo_root()
-- The six unit tests are #[cfg(target_os = "linux")]: elsewhere cargo runs 0
-- of them, which is not a red, it is a regime with no subject.
local uname = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
if uname ~= "Linux" then T:skip("linux-only-unit-tests:" .. uname) end

local cargo = { "cargo" }
if proc.run{ argv = { "which", "cargo" } }.code ~= 0 then cargo = { "toolbox", "run", "cargo" } end

local function arm(label, filter)
    local argv = {}
    for _, a in ipairs(cargo) do argv[#argv + 1] = a end
    for _, a in ipairs{ "test", "-p", "tillandsias-headless", "--bin", "tillandsias", filter, "--", "--exact" } do
        argv[#argv + 1] = a
    end
    argv.cwd = ROOT
    argv.timeout_ms = 1800000
    argv.env = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = env.get("HOME") or "" }
    local r = T:run(argv)
    local o = (r.stdout or "") .. (r.stderr or "")
    local tail = o:sub(-1200)
    T:arm(label, r.code == 0 and o:find("test result: ok. 1 passed", 1, true) ~= nil,
        "status=" .. tostring(r.status) .. " rc=" .. tostring(r.code) .. "\n" .. tail)
end

arm("parse", "tests::ipv6_probe_addresses_parse")
arm("one-blackhole", "tests::ipv6_egress_one_blackholing_router_is_not_functional")
arm("both-ok", "tests::ipv6_egress_all_routers_working_is_functional")
arm("no-router", "tests::ipv6_egress_no_default_router_is_not_functional")
arm("flowlabel", "tests::ipv6_flowlabel_selects_the_router_from_route_get_output")
arm("unmeasured", "tests::ipv6_could_not_measure_is_distinct_from_blackhole")

T:finish()
