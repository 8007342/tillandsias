-- @env PATH HOME
-- @trace order:2418-ct85
--
-- test-argv-batch.lua — common/argv_batch runs a long item list in batches that fit the command line.
--
--   1 2 000 items of 30 characters (about 66 000 characters) all arrive, in order, over more than one batch
--   2 PREMISE (Windows) the same list in ONE argv does not run: the limit is real here
--   3 a batch that cannot spawn makes code nil and status not "exited", never a clean 0
--   4 an empty list runs nothing and reports exited, code 0
--
-- Usage: tillandsias-plan script run scripts/lua/test-argv-batch.lua
-- Verdict: ok:argv-batch:<n> arms | violation:argv-batch:<n>-failed

local fixture = require "common.fixture"
local batch = require "common.argv_batch"
local T = fixture.new("argv-batch")

local items = {}
for i = 1, 2000 do items[i] = string.format("item-%05d-%s", i, string.rep("x", 19)) end
local r = batch.run({ "printf", "%s\n" }, items)
local lines = text.lines(r.stdout)
local same = #lines == #items
if same then for i = 1, #items do if lines[i] ~= items[i] then same = false; break end end end
T:arm("1 every item arrives, in order, over more than one batch", r.code == 0 and same and r.batches > 1,
    "code=" .. tostring(r.code) .. " lines=" .. #lines .. " batches=" .. tostring(r.batches) .. " " .. r.stderr:sub(1, 200))

if fixture.posix_shell() ~= "bash" then
    local argv = { "printf", "%s\n" }
    for _, it in ipairs(items) do argv[#argv + 1] = it end
    local one = proc.run({ argv = argv })
    T:arm("2 PREMISE (Windows) the same list in one argv does not run", one.status ~= "exited",
        "status=" .. tostring(one.status) .. " " .. (one.stderr or ""):sub(1, 200))
else
    out.line("skip: 2 not Windows; the 32 767-character limit is Windows' own")
end

local bad = batch.run({ "no-such-command-argv-batch" }, { "a", "b" })
T:arm("3 a batch that cannot spawn is code nil and not exited", bad.code == nil and bad.status ~= "exited",
    "code=" .. tostring(bad.code) .. " status=" .. tostring(bad.status))

local none = batch.run({ "printf", "x" }, {})
T:arm("4 an empty list runs nothing, exited, code 0", none.code == 0 and none.status == "exited" and none.batches == 0 and none.stdout == "",
    "code=" .. tostring(none.code) .. " batches=" .. tostring(none.batches))
T:finish()
