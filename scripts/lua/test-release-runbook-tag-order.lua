-- @trace order:2262-bke7, order:898-zhf3
--
-- test-release-runbook-tag-order.lua — skills/merge-to-main-and-release/SKILL.md
-- must not prescribe pushing the tag before the back-merge. Ported from the .sh.
--
-- That order is unexecutable where the hooks are installed (macuahuitl 2026-08-26,
-- v0.4.260826.1): a LOCAL tag is already "latest release" to verify-version-
-- monotonic.sh, which then refuses the tag push for the branch's pre-release
-- VERSION until the back-merge, and the runbook put the back-merge after the push.
-- The pressure there is toward --no-verify, on the one ref that publishes.
--
-- It proves the runbook does not PRESCRIBE the deadlocked order, not that a cut
-- succeeds. Commands are matched, not prose, so rewording a section is free.
--   1 PRESENT  both commands are there (an absent one would make 2 vacuous)
--   2 ORDER    the back-merge comes first
--   3 GONE     "after the tag push, never before" has not come back, emphasis
--              marks or not (a plain substring missed the original's **after**)
--   4 VERIFY   it tells the operator to check the tag did not move
--   5-8        each of 1-4 fails on the live text with that one thing broken
--
-- Verdict: ok:release-runbook-tag-order:<n> arms | violation:...:<n>-failed
--          | skip:release-runbook-tag-order:no-skill-file

local fixture = require "common.fixture"
local T = fixture.new("release-runbook-tag-order")
local DOC = "skills/merge-to-main-and-release/SKILL.md"
if not fs.exists(DOC) then T:skip("no-skill-file") end
local live = fs.read(DOC)
local MERGE, PUSH = "git merge origin/main", 'git push origin "${new_tag}"'
local VERIFY = 'git rev-list -n1 "${new_tag}"'

local function judge(doc)
    local r, merge, push = {}, nil, nil
    for i, l in ipairs(text.lines(doc)) do
        if not merge and l:sub(1, #MERGE) == MERGE then merge = i end
        if not push and l:sub(1, #PUSH) == PUSH then push = i end
    end
    r.present = merge ~= nil and push ~= nil
    r.order = r.present and merge < push
    r.gone = not text.is_match(doc, [[(?i)after[*_]* the tag push, never before]])
    r.verify = doc:find(VERIFY, 1, true) ~= nil
    r.where = "merge=" .. tostring(merge) .. " tag-push=" .. tostring(push)
    return r
end
local r = judge(live)
T:arm("1 PRESENT both the back-merge and the tag push are in the runbook", r.present, r.where .. " — an order it cannot find")
T:arm("2 ORDER the back-merge precedes the tag push", r.order,
    r.where .. "; the pre-push hook refuses that order with blocked:version-not-monotonic (898-zhf3)")
T:arm("3 GONE the 'after the tag push, never before' instruction", r.gone, "the instruction that created the deadlock is back")
T:arm("4 VERIFY the runbook prescribes checking the tag did not move", r.verify, "missing: " .. VERIFY)

local function plain(s, a, b)
    local i, j = s:find(a, 1, true)
    return i and s:sub(1, i - 1) .. b .. s:sub(j + 1) or s
end
local no_merge = live
while judge(no_merge).present do no_merge = plain(no_merge, "\n" .. MERGE, "\n# " .. MERGE) end
T:arm("5 a runbook without the back-merge fails PRESENT", not judge(no_merge).present and not judge(no_merge).order, "")
-- An early tag push, ahead of everything.
T:arm("6 a tag push ahead of the back-merge fails ORDER", judge(PUSH .. "\n" .. live).order == false, "")
T:arm("7 the old instruction, emphasised, fails GONE", not judge(live .. "\nRun this **after** the tag push, never before\n").gone, "")
local unv = live
while judge(unv).verify do unv = plain(unv, VERIFY, "git log") end
T:arm("8 a runbook that does not verify the tag fails VERIFY", not judge(unv).verify, "")
T:finish()
