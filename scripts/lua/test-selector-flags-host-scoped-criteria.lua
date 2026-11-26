-- @trace order:1199-aw6m, spec:ci-release, order:2380-psba
-- @env PATH HOME
--
-- test-selector-flags-host-scoped-criteria.lua — an offer must carry the constraint the
-- row already states. Ported from test-selector-flags-host-scoped-criteria.sh (2380-psba);
-- same six arms (arm 2 runs once per named host).
--
-- THE DEFECT. pickup_role says who can work the SUBJECT; exit_criteria can name who must
-- produce the EVIDENCE, and only the first is a field the selector read. 1132-r4mt (p1,
-- pickup_role any, criterion "demonstrated on a host that has actually reproduced the
-- refusal (yoga or macuahuitl)") was offered, claimed and released on lenovinha cycle after
-- cycle. HERMETIC since 1420-9jdf: the REAL selector over a SCRATCH ledger (the scratch tree
-- symlinks the real scripts/, so the selector's ROOT is the scratch tree), the plan binary
-- wrapped with --index, every seam pinned (roster, tier, caps, accels, cross-branch fold).
-- 1132-r4mt's criterion is used VERBATIM: "(yoga" is the case a space-bounded match missed.
--
--   1  the host-scoped row is MARKED for lenovinha, naming macuahuitl,yoga
--   2  CONTROL (x2): as EACH host the criteria name, the mark disappears — a selector that
--      marked every row would pass arm 1 and be worthless
--   3  CONTROL: marking is ADVISORY, the row is still offered
--   4  CONTROL: rows with no host-scoped criteria print unmarked
--   5  the host vocabulary is DERIVED from CAP_HOSTS, not a literal list in the selector
--
-- GRAMMAR ok:selector-flags-host-scoped-criteria:<n> arms
--       | violation:selector-flags-host-scoped-criteria:<n>-failed
--       | refused:selector-flags-host-scoped-criteria:<no-selector|no-plan-binary|offered-nothing>

local fixture = require "common.fixture"
local T = fixture.new("selector-flags-host-scoped-criteria")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local SEL_REL = "scripts/select-work-batch.sh"
if not fs.exists(SEL_REL) then T:refuse("no-selector", SEL_REL .. " absent") end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
fs.mkdir(W.rel .. "/plan/index.d")
T:must{ "ln", "-s", ROOT .. "/scripts", W.abs .. "/scripts" }
fs.write(W.rel .. "/plan/index.yaml", [[
plan_index:
  default_status_values: [ready, completed]
packets:
  - packet_id: fixture-host-scoped-row
    order: 990-hs01
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p1
    release_target: fixture-epic
    capability_tags: [plan]
    exit_criteria:
      - 'a test asserts the refusal is gone'
      - 'demonstrated on a host that has actually reproduced the refusal (yoga or macuahuitl), not on a host that has never seen it'
  - packet_id: fixture-plain-row-one
    order: 990-pl01
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: fixture-epic
    capability_tags: [plan]
    exit_criteria:
      - 'a test asserts the new behaviour on any host'
  - packet_id: fixture-plain-row-two
    order: 990-pl02
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: fixture-epic
    capability_tags: [plan]
]])
fs.write(W.rel .. "/plan-bin", '#!/usr/bin/env bash\nexec "' .. PLAN .. '" --index "' .. W.abs .. '/plan/index.yaml" "$@"\n')
fs.write(W.rel .. "/xbranch", "#!/usr/bin/env bash\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/plan-bin", W.abs .. "/xbranch" }   -- fs.write drops the exec bit
-- The roster in the `capability-matrix --hosts` shape, sorted: <host>\t<tier>\t<accels>.
local ROSTER = "lenovinha\tcpu\tnone\nmacuahuitl\tgpu-cuda\tnone\nyoga\tcpu\tnone"

-- Every seam pinned; ambient TILLANDSIAS_* (host kind, accels-present, agent, budget) is
-- stripped so nothing live leaks in.
local function select_as(host)
    local r = T:run{ SH, W.abs .. "/scripts/select-work-batch.sh", "linux", "--release", "v0.5", "--budget", "3",
        "--seed", "host-scoped-fixture", cwd = "/", timeout_ms = 120000, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_PLAN_BIN = W.abs .. "/plan-bin", TILLANDSIAS_CAP_HOSTS = ROSTER,
            TILLANDSIAS_WORKSTATION = host, TILLANDSIAS_HOST_TIER = "general", TILLANDSIAS_HOST_CAPS = "nix",
            TILLANDSIAS_HOST_ACCELS = "", TILLANDSIAS_XBRANCH_CHECK = W.abs .. "/xbranch" } }
    return r.stdout or ""
end
local function rows(out, kind)   -- field 2 of every line whose field 1 is kind; and field 3 by field 2
    local t, third = {}, {}
    for _, l in ipairs(text.lines(out)) do
        local f1, f2, f3 = l:match("^([^\t]*)\t([^\t]*)\t?([^\t]*)")
        if f1 == kind then t[#t + 1] = f2; if third[f2] == nil then third[f2] = f3 end end
    end
    return t, third
end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

local OUT = select_as("lenovinha")
local offered = rows(OUT, "packet")
if #offered == 0 then
    T:refuse("offered-nothing", "the selector offered nothing from the fixture ledger: " .. OUT:sub(1, 300))
end
local MARKED = "990-hs01"
local marked, mark_line = rows(OUT, "host-scoped")
local ML = mark_line[MARKED] or ""

T:arm("1 " .. MARKED .. " marked for lenovinha, naming macuahuitl,yoga",
    text.contains(ML, "name macuahuitl,yoga and not lenovinha"), ML == "" and "not marked" or ML)

for _, named in ipairs({ "macuahuitl", "yoga" }) do
    T:arm("2 not marked as " .. named .. " — the mark reads the criteria, it does not fire blindly",
        not has((rows(select_as(named), "host-scoped")), MARKED), "still marked as " .. named)
end

T:arm("3 " .. MARKED .. " is still in the batch — a host that cannot close it can still advance it",
    has(offered, MARKED), "the marked row was withheld from the batch")

local extra = {}
for _, o in ipairs(marked) do if o ~= MARKED then extra[#extra + 1] = o end end
T:arm("4 only " .. MARKED .. " is marked; the rows naming no host are not", #extra == 0, table.concat(extra, " "))

local SEL = fs.read(SEL_REL)
T:arm("5 the roster feeds the matcher; no literal host list in the selector",
    text.contains(SEL, "CAP_HOSTS") and not text.is_match(SEL, [==[(?m)^[[:space:]]*_hs_roster="(yoga|macuahuitl|lenovinha)]==]),
    "a hardcoded host list appeared in the selector")

T:finish()
