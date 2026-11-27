-- @env PATH HOME
-- @trace order:1201-9it2, order:748-tkjx, spec:ci-release, order:2324-xme7
--
-- test-land-notice-names-unrun-litmus.lua — before a push the land tool names the litmus arms
-- asserting on the changed files that ./build.sh --check did not run. Ported from the .sh of
-- the same name (2324-xme7); same five arms. A NOTICE and not a gate: --check runs no litmus
-- on purpose (748-tkjx), and a slow gate gets bypassed. The silence cost three reds that rode
-- a green gate to trunk.
--
-- Arm 2 is the load-bearing one: it asks the real map about the real commit that went red.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-notice-names-unrun-litmus.lua
-- Verdict: ok:land-notice-names-unrun-litmus:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("land-notice-names-unrun-litmus")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LAND = fs.read("scripts/land-on-platform-branch.sh")
local code, n, notice, push, ask = {}, 0, nil, nil, nil
for l in (LAND .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    code[n] = l:find("^%s*#") and "" or l
    if text.contains(code[n], "litmus-covering-specs.sh") then ask = ask or n end
    if text.contains(code[n], "NOTICE — ") and text.contains(code[n], "1201-9it2") then notice = notice or n end
    if text.contains(code[n], "attempt $attempt — push") then push = push or n end
end
T:arm("1 the land tool asks the map and prints the notice before the push", ask and notice and push and ask < notice and notice < push or false,
    tostring(ask) .. " " .. tostring(notice) .. " " .. tostring(push))

local function map(paths)
    local argv = { SH, ROOT .. "/scripts/litmus-covering-specs.sh" }
    for _, p in ipairs(paths) do argv[#argv + 1] = p end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local specs = 0
    for l in ((r.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
        if l:find("^[^\t]*\tspec:") then specs = specs + 1 end
    end
    return specs, (r.stdout or ""), "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")
end
-- 4fc7be930 bumped WIRE_VERSION 3 -> 4 against a pin of 3 in this arm.
local COMMIT, ARM = "4fc7be930", "guest-container-metrics-wire-shape"
if T:run{ "git", "cat-file", "-e", COMMIT .. "^^{commit}", cwd = ROOT }.code == 0 then
    local paths = {}
    for p in (T:must{ "git", "diff", "--name-only", COMMIT .. "^", COMMIT, cwd = ROOT }.stdout):gmatch("[^\r\n]+") do paths[#paths + 1] = p end
    local specs, o, why = map(paths)
    T:arm("2 the map names the arm that went red, from that commit's paths", #paths > 0 and specs > 0 and text.contains(o, ARM), #paths .. " paths " .. why .. o:sub(1, 200))
else
    out.line("skip: 2 " .. COMMIT .. " is not in this clone (shallow?)")
end
local d = T:scratch()
fs.write(d.rel .. "/plan-only-probe.md", "prose\n")
local specs, o, why = map{ d.abs .. "/plan-only-probe.md" }
T:arm("3 CONTROL an uncovered path yields no spec line", specs == 0, why .. o:sub(1, 200))
local exits = {}
for i = notice or 1, push or 0 do
    if code[i]:find("%f[%w]exit [1-9]") or code[i]:find("%f[%w]return [1-9]") then exits[#exits + 1] = i .. ": " .. code[i] end
end
T:arm("4 CONTROL nothing between the notice and the push can fail the land", notice and push and #exits == 0 or false, table.concat(exits, " | "))
T:arm("5 the notice itself cites why those arms were not run", notice and text.contains(code[notice], "748-tkjx") or false, tostring(notice and code[notice]))
T:finish()
