-- @trace order:1132-r4mt, order:965-sxec, order:2346-754w
--
-- test-archiver-could-not-run-is-self-naming.lua — every exit-3 site of archive-plan-packets.sh
-- names its cause. Ported from the .sh of the same name (2346-754w). Source text, not execution:
-- the sites need conditions no host can create on demand. Sites are found by their text, never
-- by line number.
--
--   1 each `exit 3` has a token echo within the 12 lines above it. Small on purpose: matching
--     the token anywhere credits a comment, and a window back to the previous site borrows
--     another site's token.
--   2 the causes are distinct          3 both no-usable-ruby paths share one spelling
--   4 NC the gate's forge skip keys only on the ruby token
--   5 no token goes to stderr, where the reader does not look
--
-- Usage: tillandsias-plan script run scripts/lua/test-archiver-could-not-run-is-self-naming.lua
-- Verdict: ok:archiver-could-not-run-is-self-naming:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("archiver-could-not-run-is-self-naming")
local SRC = fs.read("scripts/archive-plan-packets.sh"):gsub("\r", "")
-- The ONE exception: this site's token is the fleet-wide refusal grammar's, spelled the same elsewhere.
local EXCEPTION, WINDOW = "refused:no-plan-binary", 12
local lines = {}
for l in (SRC .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
local function named(l)
    local said = l:match('^%s*echo "(.*)')
    return said ~= nil and (said:sub(1, 14) == "could-not-run:" or said:sub(1, #EXCEPTION) == EXCEPTION)
end
local sites, missing, stderr = 0, {}, {}
for i, l in ipairs(lines) do
    if l:match("^%s*exit 3%s*$") then
        sites = sites + 1
        local hit = false
        for j = math.max(1, i - WINDOW), i do hit = hit or named(lines[j]) end
        if not hit then missing[#missing + 1] = tostring(i) end
    end
    if l:find('echo "could%-not%-run:[^"]*".*>&2') then stderr[#stderr + 1] = tostring(i) end
end
T:arm("1a PREMISE exit-3 sites are found", sites > 0, "a matcher that finds none looks exactly like a clean result")
T:arm("1b every exit-3 site names its cause", #missing == 0, #missing .. " of " .. sites .. " unnamed, lines " .. table.concat(missing, " "))
local causes, n, ruby = {}, 0, 0
-- Echo lines only: the comments explaining a token spell it too.
for _, l in ipairs(lines) do
    local t = named(l) and l:match("could%-not%-run:([a-z0-9:%-]+)")
    if t and not causes[t] then causes[t] = true; n = n + 1 end
    if t == "no-usable-ruby" then ruby = ruby + 1 end
end
T:arm("2 at least five distinct causes", n >= 5, "distinct=" .. n)
T:arm("3 both no-usable-ruby paths emit the same token", ruby >= 2, "occurrences=" .. ruby)
local skips, other = 0, {}
for t in fs.read("scripts/lua/check-archiver-ready-set.lua"):gmatch('find%("could%-not%-run:([^"]*)') do
    if t:sub(1, 14) == "no-usable-ruby" then skips = skips + 1 else other[#other + 1] = t end
end
T:arm("4 NC the forge skip keys on the ruby token and no other", skips > 0 and #other == 0, "ruby=" .. skips .. " other: " .. table.concat(other, " "))
T:arm("5 every token is written to stdout", #stderr == 0, "lines " .. table.concat(stderr, " "))
T:finish()
