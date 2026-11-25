-- @env PATH HOME
-- @trace order:1252-znbn, order:2324-xme7
--
-- test-litmus-item-opener-refused.lua — a critical_path item opened by any key other than
-- `step:` is a PARSE ERROR, not a silent backwards merge. Ported from the .sh of the same name
-- (2324-xme7). An item opened by `- name:` fell through the parser and its keys OVERWROTE the
-- step in progress: a two-item file yielded ONE unlabelled step, exit 0, no diagnostic, on
-- well-formed YAML.
--
--   1 a `- name:` item is refused, naming the key   2 an unquoted step name is refused
--   3 MUTATION with the fix taken out, the silent merge returns (1 step, exit 0)
--   4 CONTROL a valid file parses as exactly 2 steps: the defect is a wrong COUNT, not an rc
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-item-opener-refused.lua
-- Verdict: ok:litmus-item-opener-refused:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-item-opener-refused")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
local function file(name, second)
    fs.write(d.rel .. "/" .. name .. ".yaml", "test: litmus-probe-" .. name .. "\nsize: instant\nseverity: low\nphase: pre-build\ncritical_path:\n"
        .. '  - step: "first item"\n    command: "echo ok:first"\n    timeout_ms: 5000\n    expected_behavior: "ok:first"\n'
        .. "  - " .. second .. '\n    command: "echo ok:second"\n    timeout_ms: 5000\n    expected_behavior: "ok:second"\n')
end
file("merged", 'name: "second item, opened by the WRONG key"')
file("valid", 'step: "second item"')
file("unquoted", "step: unquoted name here")
local function parse(runner, name)
    local r = T:run{ SH, runner, "--parse-only", d.abs .. "/" .. name .. ".yaml", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400)
end
local RUNNER = ROOT .. "/scripts/run-litmus-test.sh"
local rc, o, why = parse(RUNNER, "merged")
T:arm("1 a '- name:' item is refused, naming the key", rc ~= 0 and text.contains(o, "PARSE ERROR") and text.contains(o, "'- name:'"), why)
rc, o, why = parse(RUNNER, "unquoted")
T:arm("2 an unquoted step name is refused, naming the remedy", rc ~= 0 and text.contains(o, "double-quoted scalar"), why)
-- The smallest mutation that restores the old path: the item is no longer recorded.
local mutant, n = fs.read("scripts/run-litmus-test.sh"):gsub("(\n *)malformed_items%+=[^\n]*", "%1:")
if n ~= 1 then T:refuse("mutation-did-not-apply", "malformed_items+= appears " .. n .. " times") end
fs.write(d.rel .. "/mutant.sh", mutant)
rc, o, why = parse(d.abs .. "/mutant.sh", "merged")
T:arm("3 MUTATION without the fix two items merge into 1 step, exit 0", rc == 0 and text.contains(o, ":1 step(s)"), why)
rc, o, why = parse(RUNNER, "valid")
T:arm("4 CONTROL a valid two-item file parses as exactly 2 steps", rc == 0 and text.contains(o, ":2 step(s)"), why)
T:finish()
