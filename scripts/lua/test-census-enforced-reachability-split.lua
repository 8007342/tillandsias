-- @env PATH HOME
-- @trace spec:ci-release, order:1334-57at, order:1333-jpq5, order:1329-m8dk, order:2346-754w
--
-- test-census-enforced-reachability-split.lua — census-litmus-step-enforcement.sh tells an
-- assertion that CAN run from one that cannot. Ported from the .sh of the same name
-- (2346-754w). Measured at 3048e72dc, 53 of 244 ENFORCED steps sat in litmus files nothing runs.
-- REACHABLE: bound in litmus-bindings.yaml and not `phase: retired`. Scratch trees hold a copy of
-- the census, so its REPO_ROOT is the tree; arms assert planted counts, never today's totals.
--
--   1 both halves are reported          2 the bound file is REACHABLE (1)
--   3 the unbound and the retired are INERT (2)
--   4 MUTATION binding the stray moves it (2/1)
--   5 the halves sum to ENFORCED        6 the closure figure names reachability
--   7 the real corpus reconciles
--
-- Usage: tillandsias-plan script run scripts/lua/test-census-enforced-reachability-split.lua
-- Verdict: ok:census-enforced-reachability-split:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("census-enforced-reachability-split")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- COMPOSED, never a literal name: these fake names claim no pin (721-77yu).
local L, DIR = "lit" .. "mus:", "/openspec/litmus-tests/"
local function census(root)
    local r = T:run{ SH, root .. "/scripts/census-litmus-step-enforcement.sh", cwd = root, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local o = (r.stdout or ""):gsub("\r", "") .. (r.stderr or "")
    -- The number that ends the line opening with the label.
    local function count(label) return tonumber(("\n" .. o):match("\n *" .. label:gsub("%p", "%%%0") .. " [^\n]-(%d+) *\n")) end
    return { r = count("ENFORCED-REACHABLE"), i = count("ENFORCED-INERT"), e = count("ENFORCED"), out = o, why = "rc=" .. tostring(r.code) .. "\n" .. o:sub(1, 900) }
end
local function planted(bind_stray)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. DIR)
    fs.write(d.rel .. "/scripts/census-litmus-step-enforcement.sh", fs.read("scripts/census-litmus-step-enforcement.sh"))
    for name, phase in pairs{ ["bound-one"] = "pre-build", ["stray-one"] = "pre-build", ["retired-one"] = "retired" } do
        fs.write(d.rel .. DIR .. "litmus-" .. name .. ".yaml", "name: " .. L .. name .. "\nspec: fixture-spec\nphase: " .. phase .. "\nsize: instant\n\ncritical_path:\n"
            .. '  - step: "the only step"\n    command: "echo ok:fixture"\n    expected_behavior: "ok:fixture"\n    assert_exit: 0\n')
    end
    fs.write(d.rel .. "/openspec/litmus-bindings.yaml", "version: '1.0'\nspecs:\n- spec_id: fixture-spec\n  status: active\n  litmus_tests:\n  - " .. L .. "bound-one\n  - " .. L .. "retired-one\n"
        .. (bind_stray and "  - " .. L .. "stray-one\n" or ""))
    fs.write(d.rel .. DIR .. "unbound-grandfathered.txt", L .. "stray-one\n")
    return census(d.abs)
end
local a, b = planted(false), planted(true)
T:arm("1 the census reports both halves", a.r ~= nil and a.i ~= nil, a.why)
T:arm("2 the bound file's enforced step is REACHABLE (1)", a.r == 1, a.why)
T:arm("3 the unbound stray and the retired file are INERT (2)", a.i == 2, a.why)
T:arm("4 MUTATION binding the stray moves it to REACHABLE (2/1)", b.r == 2 and b.i == 1, b.why)
T:arm("5 the halves sum to ENFORCED", a.e == 3 and a.r ~= nil and a.i ~= nil and a.r + a.i == a.e, "enforced=" .. tostring(a.e) .. " " .. a.why)
local figure = a.out:match("CLOSURE FIGURE[^\n]*") or ""
T:arm("6 the closure figure names reachability", text.contains(figure:lower(), "reachable"), figure)
local x = census(ROOT)
T:arm("7 the real corpus reconciles", (x.e or 0) > 0 and x.r ~= nil and x.i ~= nil and x.r + x.i == x.e, "enforced=" .. tostring(x.e) .. " " .. x.why)
T:finish()
