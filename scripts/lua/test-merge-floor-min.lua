-- @trace order:2118-asur
-- @env TILLANDSIAS_PLAN_BIN PATH HOME
--
-- test-merge-floor-min.lua — litmus:floor-merge-driver-merges-clean.
-- Two sibling branches each lower a line of the SAME floor file (adjacent
-- lines, both shapes: `path N` and `N path`), one removes a key, one adds
-- a key. Without the driver git conflicts (the NEGATIVE CONTROL arm runs the
-- same merge with the attribute absent); with merge=floor-min it merges clean
-- and every count is the key-wise minimum.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<plan binary> tillandsias-plan script run scripts/lua/test-merge-floor-min.lua
-- Verdict: ok:merge-floor-min:<n> arms | violation:merge-floor-min:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("merge-floor-min")

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not BIN or BIN == "" then T:refuse("no-plan-binary", "set TILLANDSIAS_PLAN_BIN (the litmus step does)") end
local driver_src = fs.read("scripts/lua/merge-floor-min.lua")
if not driver_src then T:refuse("no-driver", "scripts/lua/merge-floor-min.lua is missing") end

local PIPE = "scripts/portability/pipe-site-floor.txt"
local JQ = "scripts/portability/jq-callsite-floor.txt"

local function build(with_attr)
    local d = T:git_repo(with_attr and "driver" or "control")
    local g = function(...) return T:must{ "git", "-C", d.abs, ... } end
    fs.mkdir(d.rel .. "/scripts/lua")
    fs.mkdir(d.rel .. "/scripts/portability")
    fs.write(d.rel .. "/scripts/lua/merge-floor-min.lua", driver_src)
    fs.write(d.rel .. "/.gitattributes", with_attr and "scripts/portability/*-floor.txt merge=floor-min\n" or "")
    g("config", "merge.floor-min.driver",
        '"$TILLANDSIAS_PLAN_BIN" script run scripts/lua/merge-floor-min.lua -- %O %A %B')
    fs.write(d.rel .. "/" .. PIPE, "# header\nscripts a.sh 5\nscripts b.sh 3\nscripts c.sh 2\n")
    fs.write(d.rel .. "/" .. JQ, "4 lit/x.yaml\n4 lit/y.yaml\n")
    g("add", "-A"); g("commit", "-q", "-m", "base")
    g("checkout", "-q", "-b", "left")
    fs.write(d.rel .. "/" .. PIPE, "# header\nscripts a.sh 4\nscripts b.sh 3\nscripts c.sh 2\n")
    fs.write(d.rel .. "/" .. JQ, "3 lit/x.yaml\n4 lit/y.yaml\n")
    g("commit", "-q", "-a", "-m", "left lowers a and x")
    g("checkout", "-q", "main"); g("checkout", "-q", "-b", "right")
    -- lowers a further and y; removes c (fell to zero); adds d.
    fs.write(d.rel .. "/" .. PIPE, "# header\nscripts a.sh 2\nscripts b.sh 3\nscripts d.sh 1\n")
    fs.write(d.rel .. "/" .. JQ, "4 lit/x.yaml\n1 lit/y.yaml\n")
    g("commit", "-q", "-a", "-m", "right lowers a and y, drops c, adds d")
    g("checkout", "-q", "left")
    local r = T:run{ "git", "-C", d.abs, "merge", "-q", "--no-edit", "right",
        env = { TILLANDSIAS_PLAN_BIN = BIN, PATH = env.get("PATH"), HOME = env.get("HOME") } }
    return d, r
end

-- NEGATIVE CONTROL: the same histories without the attribute conflict.
local _, control = build(false)
T:arm("control: without the driver the sibling floors conflict", control.code ~= 0,
    "merged clean without the driver — the fixture has no subject")

local d, r = build(true)
T:arm("with merge=floor-min the merge is clean", r.code == 0, tostring(r.stderr or r.stdout))
local pipe = fs.read(d.rel .. "/" .. PIPE) or ""
local jq = fs.read(d.rel .. "/" .. JQ) or ""
T:arm("both sides lowered a.sh: the lower count wins", pipe:find("scripts a.sh 2\n", 1, true) ~= nil, pipe)
T:arm("a key one side removed stays removed", pipe:find("c.sh", 1, true) == nil, pipe)
T:arm("a key one side added is kept", pipe:find("scripts d.sh 1\n", 1, true) ~= nil, pipe)
T:arm("comments survive", pipe:find("# header\n", 1, true) == 1, pipe)
T:arm("count-first shape: each side's lowering is kept",
    jq == "3 lit/x.yaml\n1 lit/y.yaml\n", jq)
local st = T:run{ "git", "-C", d.abs, "status", "--porcelain" }
T:arm("no conflict markers or unmerged paths", (st.stdout or "") == "", st.stdout)

T:finish()
