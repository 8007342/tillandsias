-- @env PATH HOME
-- @trace order:1221-vkbj, order:1141-vf9w, order:1150-q462, spec:ci-release, order:2314-ktxt
--
-- test-competing-gate-no-dispatch-cause.lua — a silence names WHICH silence, and build.sh
-- reads the code. Ported from the .sh of the same name (2314-ktxt); same eleven checks.
-- Measured on lenovinha 2026-09-16: a host with no dispatch was told it had failed to assert
-- --host-side (nothing to fix), and build.sh then discarded the answer with `|| true`.
--
-- ARMS 4-7 ARE THE LOAD-BEARING HALF: a cause that swallows wiring bugs, or an undispatched
-- caller asserting --host-side (whose only reachable verdict is a vacuous clean, which
-- 1141-vf9w's promotion criterion would consume), is worse than the defect.
--
-- Usage: tillandsias-plan script run scripts/lua/test-competing-gate-no-dispatch-cause.lua
-- Verdict: ok:competing-gate-no-dispatch-cause:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("competing-gate-no-dispatch-cause")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local function run(...)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/check-no-competing-gate.sh", ... }, cwd = ROOT,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300)
end

local rc, undis, why = run("--caller-context", "undispatched")
T:arm("1a an undispatched caller gets a cause naming that", rc == 3 and text.contains(undis, "competing-gate:no-dispatch"), why)
T:arm("1b and is told there is nothing to fix", text.contains(undis:lower(), "nothing to fix here"), why)
local rc2, dis, why2 = run("--caller-context", "dispatched")
T:arm("2 a caller inside the dispatch gets its own cause", rc2 == 3 and text.contains(dis, "competing-gate:inside-dispatch"), why2)
T:arm("3 the two causes are different", undis ~= dis, undis:sub(1, 200))
local o
rc, o, why = run()
T:arm("4 CONTROL a caller asserting nothing still gets the loud old cause", rc == 3 and text.contains(o, "no-host-side-assertion"), why)
rc, o, why = run("--caller-context", "sideways")
T:arm("5 CONTROL a bad context value is a caller-contract refusal, 2 and not 3", rc == 2 and text.contains(o, "caller-contract"), why)

local build, named, asserts = fs.read("build.sh"), 0, ""
local invocation, n = nil, 0
local lines = {}
for l in (build .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1; lines[n] = l
    if text.contains(l, "check-no-competing-gate.sh") then
        named = named + 1
        if text.contains(l, "host-side") then asserts = asserts .. n .. " " end
        if not invocation and l:find("_run bash .*check%-no%-competing%-gate%.sh") then invocation = n end
    end
end
T:arm("6 CONTROL build.sh names the check and never asserts --host-side", named > 0 and asserts == "", named .. " lines; asserts at " .. asserts)
rc, o, why = run("--host-side", "1", "--caller-context", "undispatched")
T:arm("7 CONTROL asserting both is refused for that, not answered", rc == 2 and text.contains(o, "must not also assert --caller-context"), why)

-- ANCHORED on the invocation and the handler after it: a sed range to the next esac spans
-- 921 lines on the pre-fix tree and scores four unrelated `|| true`s.
local site = invocation and table.concat(lines, "\n", invocation, math.min(invocation + 14, n)) or ""
T:arm("8a the exit code is captured, not discarded", invocation ~= nil and not text.contains(site, "|| true"), site)
local function case(label) return ("\n" .. site):find("\n *" .. label .. "%)") ~= nil end
T:arm("8b 2, 3 and an unknown code are each handled", case("2") and case("3") and case("%*"), site)
local exits = ("\n" .. site):find("\n *[23]%)[^\n]*exit ") ~= nil
T:arm("9 the check stays advisory: no exit path at the call site", invocation ~= nil and not exits
    and text.contains(fs.read("scripts/check-no-competing-gate.sh"), "TILLANDSIAS_COMPETING_GATE_ADVISORY"), site)
T:finish()
