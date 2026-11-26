-- @trace order:1303-2d5g, order:1611-imnj, order:2387-lrg2, spec:litmus-framework
--
-- test-litmus-parse-instruments-agree.lua — `run-litmus-test.sh --parse-only` used to answer
-- `ok:` (with a step count) for a file `tillandsias-plan validate-yaml` REFUSES, because its
-- extraction is line-based and never loaded the document (1303-2d5g). Ported from
-- test-litmus-parse-instruments-agree.sh (2387-lrg2); same premise and three arms, in order.
--
--   0  PREMISE   validate-yaml refuses bad.yaml (else nothing below means anything: refused)
--   1  --parse-only refuses bad.yaml: non-zero, no `ok:` line, the file named
--   2  a valid file is accepted by BOTH instruments
--   3  MUTATION  the load gated off (`_parse_load_enabled=0`, the anchor the runner owns and
--                test-litmus-parse-only-duplicate-key.lua mutates too): arm 1 stops holding
--
-- The fixtures live in scratch, never in openspec/litmus-tests (the strict gate globs it).
-- The mutant lives in scratch with its BASH_SOURCE root lookup pinned to the checkout (1611-imnj).
--
-- GRAMMAR ok:litmus-parse-instruments-agree:<n> arms
--       | violation:litmus-parse-instruments-agree:<n>-failed
--       | skip:litmus-parse-instruments-agree:no-runnable-reader

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local T = fixture.new("litmus-parse-instruments-agree")
local ROOT = fixture.repo_root()
local RUNNER = ROOT .. "/scripts/run-litmus-test.sh"
local READER = fixture.plan_binary()
if READER == "" then T:skip("no-runnable-reader") end
if not fixture.is_abs(READER) then READER = ROOT .. "/" .. READER:gsub("^%./", "") end

local W = T:scratch()
local BAD, GOOD = W.abs .. "/bad.yaml", W.abs .. "/good.yaml"
-- 933-4gm8's shape: a plain-scalar list item carrying ": " and continuing onto a second line.
fs.write(W.rel .. "/bad.yaml", [[
name: fixture-not-yaml
spec: fixture-spec
phase: pre-build
description: >
  Deliberately unparseable. Used only by this fixture.
severity: low
size: instant

preconditions:
  - this item is the hazard: a plain scalar carrying a colon-space pair
    and continuing onto a second line

critical_path:
  - step: "a step that does nothing"
    command: "echo ok"
    expected_behavior: "ok"
    assert_exit: 0
    timeout_ms: 1000
]])
fs.write(W.rel .. "/good.yaml", [[
name: fixture-valid
spec: fixture-spec
phase: pre-build
description: >
  Valid YAML and extractable. Used only by this fixture.
severity: low
size: instant

critical_path:
  - step: "a step that does nothing"
    command: "echo ok"
    expected_behavior: "ok"
    assert_exit: 0
    timeout_ms: 1000
]])

local function both(r) return (r.stdout or "") .. (r.stderr or "") end
local function any_line(s, pat)
    for _, l in ipairs(text.lines(s)) do if l:match(pat) then return true end end
    return false
end
local function parse_only(runner, file)
    local r = T:run{ SH, runner, "--parse-only", file, cwd = ROOT, timeout_ms = 120000 }
    return r.code, both(r)
end
local function tail3(s)
    local ls, t = text.lines(s), {}
    for i = math.max(1, #ls - 2), #ls do t[#t + 1] = ls[i] end
    return table.concat(t, " | ")
end

-- ARM 0 (premise)
if T:run{ READER, "validate-yaml", BAD, cwd = ROOT, timeout_ms = 30000 }.code == 0 then
    T:refuse("premise-broken", "validate-yaml ACCEPTED the deliberately-bad fixture")
end

-- ARM 1
local rc1, o1 = parse_only(RUNNER, BAD)
T:arm("ARM 1: --parse-only refuses a non-YAML file, with no ok: line, naming the file",
    rc1 ~= 0 and not any_line(o1, "^ok:") and text.contains(o1, "bad.yaml"),
    "rc=" .. tostring(rc1) .. " " .. tail3(o1))

-- ARM 2
local rc2, o2 = parse_only(RUNNER, GOOD)
local src = T:run{ READER, "validate-yaml", GOOD, cwd = ROOT, timeout_ms = 30000 }.code
T:arm("ARM 2: a valid file is accepted by both instruments",
    rc2 == 0 and src == 0 and any_line(o2, "^ok:litmus%-parseable"),
    "runner=" .. tostring(rc2) .. " strict=" .. tostring(src) .. " " .. tail3(o2))

-- ARM 3 (mutation): gate the load off at the runner's own anchor line; pin the root lookup.
local LOOKUP = '$(dirname "${BASH_SOURCE[0]}")'
local outl, load_hits = {}, 0
for _, l in ipairs(text.lines(fs.read("scripts/run-litmus-test.sh"))) do
    if l:match("^ *local _parse_load_enabled=1 ") then
        l = "                local _parse_load_enabled=0 # neutralised for arm 3"; load_hits = load_hits + 1
    end
    local i = 1
    while true do
        local s, e = l:find(LOOKUP, i, true)
        if not s then break end
        l = l:sub(1, s - 1) .. ROOT .. "/scripts" .. l:sub(e + 1); i = s + #ROOT + 8
    end
    outl[#outl + 1] = l
end
local mtext = table.concat(outl, "\n") .. "\n"
fs.write(W.rel .. "/run-litmus-test.mutant-1303.sh", mtext)
local MUT = W.abs .. "/run-litmus-test.mutant-1303.sh"
if text.contains(mtext, "BASH_SOURCE") then
    T:arm("ARM 3: the mutant resolves no path from its own location", false,
        "a BASH_SOURCE lookup survived; pin the new lookup")
elseif load_hits == 0 then
    T:arm("ARM 3: the load-gate mutation applies", false, "the `local _parse_load_enabled=1` anchor has been reworded")
elseif T:run{ SH, "-n", MUT }.code ~= 0 then
    T:arm("ARM 3: the mutant parses", false, "bash -n refused the mutant")
else
    local rcm, om = parse_only(MUT, BAD)
    T:arm("ARM 3: MUTATION with the load removed, --parse-only says ok: for the bad file again",
        rcm == 0 and any_line(om, "^ok:litmus%-parseable"), "rc=" .. tostring(rcm) .. " " .. tail3(om))
end

T:finish()
