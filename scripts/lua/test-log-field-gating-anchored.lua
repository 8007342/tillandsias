-- @env PATH HOME
-- @trace order:2403-4ibs
--
-- test-log-field-gating-anchored.lua — litmus:log-field-stability-schema's gating_points failure
-- regexes match a VERDICT line, never free text: a passing run whose output contains the word
-- "error" in a crate name is not failed by them, and a real cargo error still is.
--
-- WHY (2403-4ibs). The runner greps each `failure:` regex against the COMBINED output of every
-- step (grep -qE, as here). The patterns were bare words ("error", "mismatch|error"), and a cold
-- build prints "Compiling thiserror v2.0.18" (a dependency of tillandsias-logging), so the litmus
-- passed all 13 steps and was then failed by a crate name, on a cold target only.
--
--   1 a passing output with "Compiling thiserror" and "Checking num-traits" matches no failure regex
--   2 CONTROL a real cargo error line ("error[E0308]: mismatched types") matches at least one
--   3 PREMISE the litmus declares failure regexes at all (a parse that found none would pass arm 1)
--
-- Usage: tillandsias-plan script run scripts/lua/test-log-field-gating-anchored.lua
-- Verdict: ok:log-field-gating-anchored:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("log-field-gating-anchored")
local Y = "openspec/litmus-tests/litmus-log-field-stability-schema.yaml"
local pats = {}
local in_gating = false
for l in (fs.read(Y) .. "\n"):gmatch("([^\n]*)\n") do
    if l:match("^gating_points:") then in_gating = true
    elseif l:match("^%S") then in_gating = false
    elseif in_gating then
        local p = l:match("^%s+failure:%s*\"(.*)\"%s*$") or l:match("^%s+failure:%s*'(.*)'%s*$")
        if p then pats[#pats + 1] = p end
    end
end
T:arm("3 PREMISE the litmus declares failure regexes", #pats >= 3, #pats .. " found")
-- The runner reads each regex from the YAML its own way; with no backslash in any of them, every
-- reader (this fixture, the runner's parser, yq) sees the same regex. A backslash here once made
-- the runner's anchor match nothing while this fixture's copy matched (2403-4ibs).
local slashed = {}
for _, p in ipairs(pats) do if p:find("\\", 1, true) then slashed[#slashed + 1] = p end end
T:arm("3 PREMISE no failure regex carries a backslash", #slashed == 0, table.concat(slashed, " | "))
local PASSING = table.concat({
    -- the runner joins each step's output onto "[i:step]" on the same line (run-litmus-test.sh)
    "[8:run log entry unit tests]   Compiling thiserror v2.0.18", "   Compiling thiserror-impl v2.0.18 (proc-macro)",
    "    Checking num-traits v0.2.19", "Schema versions match: 1.0.0",
    "All core fields marked immutable", "All required core fields found in code",
    "test result: ok. 12 passed; 0 failed; 0 ignored", "" }, "\n")
-- A first-line error behind the runner's prefix: the one place a bare ^ anchor cannot see.
local ERROR = "[8:run log entry unit tests]error[E0308]: mismatched types\n  --> crates/tillandsias-logging/src/log_entry.rs:42:5\n"
local function matches(p, text_)
    return T:run{ "grep", "-qE", "--", p, stdin = text_, timeout_ms = 10000 }.code == 0
end
local hit = {}
for _, p in ipairs(pats) do if matches(p, PASSING) then hit[#hit + 1] = p end end
T:arm("1 a passing output that names thiserror trips no failure regex", #hit == 0, "matched: " .. table.concat(hit, " | "))
local any = false
for _, p in ipairs(pats) do if matches(p, ERROR) then any = true end end
T:arm("2 CONTROL a real cargo error still trips one", any, "no regex matched a cargo error line")
T:finish()
