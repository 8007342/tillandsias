-- @trace order:2417-jzhh
--
-- test-listed-read-reader.lua: common.listed_read.reader, which the census
-- arms of ten fixtures use (2417-jzhh, the B-fixture batch). A loop that
-- filters as it walks reads each file through R:read(f); R:done() then blocks
-- (exit 2) naming every file that failed, once, as read_all does.
--
-- A driver script in scratch reads a readable file and a chmod 000 one (the
-- locked one twice). chmod 000 does not stop root, so a planted file that
-- still reads skips rather than passing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-reader.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-reader")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("reader")

fs.write(W.rel .. "/a.txt", "a\n")
fs.write(W.rel .. "/locked.txt", "b\n")
fs.write(W.rel .. "/driver.lua", table.concat({
    'local R = require("common.listed_read").reader("reader-probe")',
    'local got = 0',
    'for _, f in ipairs({ "' .. W.rel .. '/a.txt", "' .. W.rel .. '/locked.txt", "' .. W.rel .. '/locked.txt" }) do',
    '    if R:read(f) then got = got + 1 end',
    'end',
    'R:done()',
    'verdict.emit("ok:reader-probe:read=" .. got, 0)', "" }, "\n"))

local function run()
    local r = T:run{ PLAN, "script", "run", W.abs .. "/driver.lua", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(-400):gsub("\n", " | ")
end

T:must{ "chmod", "000", W.abs .. "/locked.txt" }
if pcall(fs.read, W.rel .. "/locked.txt") then
    T:run{ "chmod", "644", W.abs .. "/locked.txt" }
    T:skip("could-not-plant: chmod 000 left the file readable (running as root?)")
end
local rc, o, why = run()
T:arm("1 an unreadable file blocks at done(), exit 2", rc == 2 and text.contains(o, "blocked:reader-probe:unreadable:1"), why)
local _, named = o:gsub("unreadable: [^\n]*locked%.txt", "")
T:arm("2 the file is named once though it was read twice", named == 1, why)
T:arm("3 nothing after done() ran", not text.contains(o, "ok:reader-probe"), why)
T:run{ "chmod", "644", W.abs .. "/locked.txt" }
local rc2, o2, why2 = run()
T:arm("4 CONTROL readable again: every read answers and done() passes", rc2 == 0 and text.contains(o2, "ok:reader-probe:read=3"), why2)
T:finish()
