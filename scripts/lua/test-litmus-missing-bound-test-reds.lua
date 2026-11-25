-- @trace order:1049-s35z, order:1083-gzqj, order:2327-ahqf
--
-- test-litmus-missing-bound-test-reds.lua — a name bound in litmus-bindings.yaml whose FILE is
-- absent makes the run FAIL, not skip. Ported from the .sh of the same name (2327-ahqf). Skips
-- are outside coverage: on yolanda two of three bound tests were unfindable and the run printed
-- 100% (1/1 executed). STATIC over the runner's not-found lines (by their message, not by a
-- window anchored on a line that is not unique) and over the corpus.
--
--   1 no not-found path skips; one FAILs, and names the bindings file
--   2 NC every bound name resolves to a file   3 the CR strip that makes the lookup work stays
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-missing-bound-test-reds.lua
-- Verdict: ok:litmus-missing-bound-test:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-missing-bound-test")
local SRC = fs.read("scripts/run-litmus-test.sh"):gsub("\r\n", "\n")
local skips, fails, scoped = {}, 0, 0
for l in (SRC .. "\n"):gmatch("([^\n]*)\n") do
    if text.contains(l, "Test file not found") then
        if text.contains(l, '"SKIP"') then skips[#skips + 1] = text.trim(l) end
        if text.contains(l, '"FAIL"') then
            fails = fails + 1
            if text.contains(l, "litmus-bindings.yaml") then scoped = scoped + 1 end
        end
    end
end
T:arm("1a no not-found path skips", #skips == 0, table.concat(skips, " | "))
T:arm("1b a missing bound test is a FAIL", fails > 0, "no FAIL line")
T:arm("1c that FAIL names the bindings file", scoped > 0, "fails=" .. fails)
local seen, n, missing = {}, 0, {}
for l in (fs.read("openspec/litmus-bindings.yaml"):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
    local name = l:match("^%s*%-%s+litmus:([%w._%-]+)")
    if name and not seen[name] then
        seen[name] = true; n = n + 1
        if not fs.exists("openspec/litmus-tests/litmus-" .. name .. ".yaml") then missing[#missing + 1] = name end
    end
end
T:arm("2a NC every bound name resolves to a file", #missing == 0, table.concat(missing, " "))
-- 100 is a DECLARED vacuity floor (1083-gzqj), not a measurement.
T:arm("2b the binding list was read", n > 100, "read " .. n .. " names; either this parser stopped matching, or the corpus shrank below 100 and the floor must be lowered on purpose")
T:arm("3 the yaml read still strips carriage returns", text.contains(SRC, "${out//$'\\r'/}"), "the strip is gone")
T:finish()
