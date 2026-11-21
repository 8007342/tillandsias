-- @trace plan:2150-qd38
-- test-gate-tree-hygiene.lua — the gate's tree-hygiene probe (2150-qd38,
-- priority:build-speed) logs PSI and warns, or with opt-in refuses, on
-- untracked scratch above the threshold.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-tree-hygiene.lua
-- Verdict: ok:gate-tree-hygiene:<n> arms | violation:gate-tree-hygiene:<n>-failed
local fixture = require "common.fixture"
local T = fixture.new("gate-tree-hygiene")
local SC = T:scratch("scaffold")
local PS = T:scratch("psi")

fs.mkdir(SC.rel .. "/scripts")
fs.write(SC.rel .. "/scripts/gate-tree-hygiene.sh", fs.read("scripts/gate-tree-hygiene.sh"))
fs.write(SC.rel .. "/.gitignore", "ignored/\n")
T:must{ "git", "-C", SC.abs, "init", "-q", "." }

for _, k in ipairs{ "cpu", "memory", "io" } do
    fs.write(PS.rel .. "/" .. k, "some avg10=1.25 avg60=3.50 avg300=0.00 total=1\nfull avg10=0.75 avg60=2.00 avg300=0.00 total=1\n")
end

local function run(args, env)
    local argv = { "bash", "scripts/gate-tree-hygiene.sh" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd = SC.abs; argv.env = env or {}
    local r = T:run(argv)
    return text.trim(r.stdout or ""), r
end

local out, r = run({ "psi", "gate-start" }, { TILLANDSIAS_PSI_ROOT = PS.abs })
T:arm("psi line carries the label and memory some/full avg10/avg60",
    r.code == 0 and out:find("psi:gate-start", 1, true) ~= nil and out:find("mem=1.25/3.50", 1, true) ~= nil
    and out:find("mem_full=0.75/2.00", 1, true) ~= nil, out)
out, r = run({ "psi", "x" }, { TILLANDSIAS_PSI_ROOT = PS.abs .. "/absent" })
T:arm("no PSI on the host -> psi:x:unavailable, exit 0", r.code == 0 and out == "psi:x:unavailable", out)

out, r = run({ "scratch" })
T:arm("clean tree -> ok:tree-scratch:0MB", r.code == 0 and text.starts_with(out, "ok:tree-scratch:0MB"), out)

-- 2 MB untracked against a 1 MB threshold; 2 MB IGNORED must not count.
fs.mkdir(SC.rel .. "/junk"); fs.mkdir(SC.rel .. "/ignored")
local blob = string.rep("x", 2 * 1024 * 1024)
fs.write(SC.rel .. "/junk/blob", blob)
fs.write(SC.rel .. "/ignored/blob", blob)
local env = { TILLANDSIAS_GATE_SCRATCH_WARN_MB = "1" }
out, r = run({ "scratch" }, env)
T:arm("untracked scratch over threshold -> warn, exit 0, names the largest root",
    r.code == 0 and text.starts_with(out, "warn:tree-scratch:2MB>1MB") and out:find("junk/", 1, true) ~= nil, out)
T:arm("ignored paths are not scratch", out:find("ignored/", 1, true) == nil, out)
env.TILLANDSIAS_GATE_SCRATCH_REFUSE = "1"
out, r = run({ "scratch" }, env)
T:arm("opt-in refuse -> exit 1, refused:tree-scratch", r.code == 1 and text.starts_with(out, "refused:tree-scratch:2MB>1MB"), out)
T:must{ "rm", "-rf", SC.abs .. "/junk" }
out, r = run({ "scratch" }, env)
T:arm("scratch removed -> ok again even with refuse on", r.code == 0 and text.starts_with(out, "ok:tree-scratch:"), out)

T:finish()
