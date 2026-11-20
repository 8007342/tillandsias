-- @trace order:2118-asur
-- @env TILLANDSIAS_PLAN_BIN PATH HOME
--
-- test-merge-litmus-bindings.lua — litmus:litmus-bindings-merge-per-spec.
-- On a copy of the REAL openspec/litmus-bindings.yaml, two sibling branches
-- each bind a new test at the end of the same spec's list, each add a new spec
-- block at the end of the file, one bumps that spec's last_verified, and one
-- unbinds a test elsewhere. Without the driver git conflicts (the NEGATIVE
-- CONTROL arm); with merge=litmus-bindings it merges clean and keeps every
-- change. A self-merge of the real registry is byte-identical.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<plan binary> tillandsias-plan script run scripts/lua/test-merge-litmus-bindings.lua
-- Verdict: ok:merge-litmus-bindings:<n> arms | violation:merge-litmus-bindings:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("merge-litmus-bindings")

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not BIN or BIN == "" then T:refuse("no-plan-binary", "set TILLANDSIAS_PLAN_BIN (the litmus step does)") end
local driver_src = fs.read("scripts/lua/merge-litmus-bindings.lua")
local real = fs.read("openspec/litmus-bindings.yaml")
if not driver_src or not real then T:refuse("missing-input", "driver or registry missing") end

local REG = "openspec/litmus-bindings.yaml"
local SPEC = "ci-release"
-- premise: the fixture's edits target a real block with a list and a last_verified line
local spec_at = real:find("\n- spec_id: " .. SPEC .. "\n", 1, true)
if not spec_at then T:refuse("premise", "no " .. SPEC .. " block in the registry") end
local next_at = real:find("\n- spec_id: ", spec_at + 1, true) or #real
local block = real:sub(spec_at + 1, next_at)
local last_test
for v in block:gmatch("\n  %- (litmus:[^\n]+)") do last_test = v end
local lv = block:match("\n  last_verified: [^\n]+")
if not last_test or not lv then T:refuse("premise", SPEC .. " block lacks tests or last_verified") end
local victim = real:match("\n  %- (litmus:agy%-install%-cached)\n")
if not victim then T:refuse("premise", "litmus:agy-install-cached is not bound") end

local function after_last_test(body, add)
    return body:gsub("\n  %- " .. last_test:gsub("%p", "%%%0") .. "\n",
        "\n  - " .. last_test .. "\n  - " .. add .. "\n", 1)
end

local function build(with_attr)
    local d = T:git_repo(with_attr and "driver" or "control")
    local g = function(...) return T:must{ "git", "-C", d.abs, ... } end
    fs.mkdir(d.rel .. "/scripts/lua")
    fs.mkdir(d.rel .. "/openspec")
    fs.write(d.rel .. "/scripts/lua/merge-litmus-bindings.lua", driver_src)
    fs.write(d.rel .. "/.gitattributes", with_attr and (REG .. " merge=litmus-bindings\n") or "")
    g("config", "merge.litmus-bindings.driver",
        '"$TILLANDSIAS_PLAN_BIN" script run scripts/lua/merge-litmus-bindings.lua -- %O %A %B')
    fs.write(d.rel .. "/" .. REG, real)
    g("add", "-A"); g("commit", "-q", "-m", "base")
    g("checkout", "-q", "-b", "left")
    local left = after_last_test(real, "litmus:left-new-test")
        .. "- spec_id: left-new-spec\n  status: active\n  litmus_tests:\n  - litmus:left-only\n  coverage_ratio: 100\n"
    fs.write(d.rel .. "/" .. REG, left)
    g("commit", "-q", "-a", "-m", "left binds a test and adds a spec")
    g("checkout", "-q", "main"); g("checkout", "-q", "-b", "right")
    local right = after_last_test(real, "litmus:right-new-test")
    right = right:gsub(lv:gsub("%p", "%%%0"), "\n  last_verified: '2026-11-20'", 1)
    right = right:gsub("\n  %- litmus:agy%-install%-cached\n", "\n", 1)
    right = right .. "- spec_id: right-new-spec\n  status: draft\n  litmus_tests: []\n"
    fs.write(d.rel .. "/" .. REG, right)
    g("commit", "-q", "-a", "-m", "right binds a test, bumps a date, unbinds one, adds a spec")
    g("checkout", "-q", "left")
    local r = T:run{ "git", "-C", d.abs, "merge", "-q", "--no-edit", "right",
        env = { TILLANDSIAS_PLAN_BIN = BIN, PATH = env.get("PATH"), HOME = env.get("HOME") } }
    return d, r
end

local _, control = build(false)
T:arm("control: without the driver the sibling bindings conflict", control.code ~= 0,
    "merged clean without the driver — the fixture has no subject")

local d, r = build(true)
T:arm("with merge=litmus-bindings the merge is clean", r.code == 0, tostring(r.stderr or r.stdout))
local got = fs.read(d.rel .. "/" .. REG) or ""
local function has(s) return got:find(s, 1, true) ~= nil end
T:arm("both sides' bindings to the same spec are kept, ours first",
    has("\n  - " .. last_test .. "\n  - litmus:left-new-test\n  - litmus:right-new-test\n"), "list tail differs")
T:arm("theirs' last_verified bump is taken (ours kept the base)", has("\n  last_verified: '2026-11-20'"), "date lost")
T:arm("a test unbound on one side stays unbound", not has("litmus:agy-install-cached"), "unbinding lost")
T:arm("both new spec blocks are present",
    has("\n- spec_id: left-new-spec\n") and has("\n- spec_id: right-new-spec\n"), "a new block is missing")
T:arm("the merged registry still parses", yaml.parse(got) ~= nil, "yaml.parse failed")
local st = T:run{ "git", "-C", d.abs, "status", "--porcelain" }
T:arm("no conflict markers or unmerged paths", (st.stdout or "") == "", st.stdout)

-- A self-merge of the real registry is byte-identical (the driver is lossless).
local s = T:scratch("identity")
for _, n in ipairs{ "b", "o", "t" } do fs.write(s.rel .. "/" .. n .. ".yaml", real) end
local id = T:run{ BIN, "script", "run", "scripts/lua/merge-litmus-bindings.lua", "--",
    s.abs .. "/b.yaml", s.abs .. "/o.yaml", s.abs .. "/t.yaml" }
T:arm("a self-merge of the real registry is byte-identical",
    id.code == 0 and fs.read(s.rel .. "/o.yaml") == real, tostring(id.stdout) .. tostring(id.stderr))

T:finish()
