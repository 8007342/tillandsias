-- @env PATH HOME
-- @trace order:2408-rkvd, order:2407-aana, order:2407-aq7x
--
-- check-test-tmp-leftovers.lua — the gate's workspace test run leaves nothing in its temp dir.
--
-- WHY (2408-rkvd). /tmp is a tmpfs with a fixed inode count. On 2026-11-26 it reached 98% of
-- 1,048,576 inodes from about 99,000 dirs that tests made and never removed, and the land queue
-- read the resulting ENOSPC as merge conflicts and evicted 19 PRs (run 93). 2407-aana and
-- 2407-aq7x made the tests clean up; this keeps the next test from undoing that.
--
-- HOW. build.sh runs the workspace tests with TMPDIR set to a fresh dir under /tmp (a TMPDIR
-- under the checkout fails tests that assert the temp dir is outside the repository), then asks
-- this check what is left there. Counting the shared /tmp before and after would measure every
-- other process on the host as well; the private dir measures only the run.
--
-- Usage: tillandsias-plan script run scripts/lua/check-test-tmp-leftovers.lua -- <dir>
-- Verdict: ok:test-tmp-leftovers:0 left | violation:test-tmp-leftovers:<n> | could-not-run:...

local NAME = "test-tmp-leftovers"
local dir = arg and arg[1]
if not dir or dir == "" then verdict.could_not_run(NAME, "no directory given (-- <dir>)") end
-- fs is confined to the repository and this dir is outside it, so ls reads it.
local r = proc.run{ argv = { "ls", "-A1", "--", dir }, timeout_ms = 30000 }
if r.status ~= "exited" or r.code ~= 0 then
    verdict.could_not_run(NAME, "cannot list " .. dir .. ": " .. tostring(r.status) .. " " .. (r.stderr or ""):sub(1, 200))
end
local names = {}
for n in (r.stdout or ""):gmatch("[^\n]+") do names[#names + 1] = n end
if #names == 0 then verdict.ok(NAME, "0 left") end
-- Group by the name with its digits and tempfile suffix folded, so 58 dirs from one helper read
-- as one line with a count.
local groups, order = {}, {}
for _, n in ipairs(names) do
    local k = n:gsub("%.tmp[%w]+$", ".tmpXXXXXX"):gsub("%d+", "N")
    if not groups[k] then groups[k] = { n = 0, example = n }; order[#order + 1] = k end
    groups[k].n = groups[k].n + 1
end
table.sort(order, function(a, b) return groups[a].n > groups[b].n end)
out.line("REFUSED: the workspace test run left " .. #names .. " entries in its temp dir " .. dir .. ":")
for i, k in ipairs(order) do
    if i > 25 then out.line("  ... and " .. (#order - 25) .. " more name shapes"); break end
    out.line(string.format("  %5d  %s   (e.g. %s)", groups[k].n, k, groups[k].example))
end
out.line("  why: /tmp is a tmpfs with a fixed inode count; on 2026-11-26 leftover test dirs filled it and the land queue evicted 19 PRs (2408-rkvd)")
out.line("  remedy: make the test that names each prefix remove its dir: tillandsias_core::test_scratch (or tillandsias_plan::test_scratch) for a path the caller keeps, tempfile::TempDir for one scope")
verdict.emit("violation:" .. NAME .. ":" .. #names, 1)
