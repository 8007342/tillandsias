-- @trace order:1083-gzqj, order:2302-yqv5
--
-- test-gate-thresholds-are-chosen.lua — a number a gate compares against must
-- have been CHOSEN, and the choice must be written down. Ported from the .sh
-- (2302-yqv5).
--
-- THE TEST TO APPLY: find the number, and ask WHO CHOSE IT AND WHERE THAT CHOICE
-- IS RECORDED. "Whatever the tree measured when the arm was written" is not a
-- threshold, it is a SNAPSHOT: it fires later, on a host that changed nothing,
-- under a label pointing at the wrong subsystem.
--
-- NOT a ban on comparing against live content: a DECLARED vacuity floor whose
-- number was chosen and stated must keep passing (arms 7, 8). A remedy that
-- outlawed it would make deleting vacuity guards the honest response.
--
-- Every arm asserts a structural property of a named fixture's source, so it is
-- textual; none asserts a moment or a count of anything that grows.
--
-- Verdict: ok:gate-thresholds-are-chosen:8 arms | violation:gate-thresholds-are-chosen:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-thresholds-are-chosen")
local CRED = "scripts/test-check-credential-channel.sh"
local SELECTOR = "scripts/test-selector-drops-cross-branch-claims.sh"
local HOOKS = "scripts/lua/test-forge-project-guard-hooks.lua"
local CONTROL = "scripts/lua/test-precommit-zero-trace-scan-scope.lua"
local src = {}
for _, f in ipairs({ CRED, SELECTOR, HOOKS, CONTROL }) do
    if not fs.exists(f) then T:refuse("subject-missing", f .. " is missing: no arm can assert over a file that is not there") end
    src[f] = fs.read(f)
end
local function has(f, s) return src[f]:find(s, 1, true) ~= nil end

-- A live-tree COUNT against a literal, with zero margin: exactly 3 against
-- `-le 3` at HEAD, HEAD~10 and HEAD~30. COMMENTS ARE NOT CODE: the replacement
-- QUOTES the old assertion to explain what was removed, so they are skipped.
local ceiling
for _, l in ipairs(text.lines(src[CRED])) do
    if not l:match("^%s*#") and l:match('%[ *"%$probes" *%-le *%d+ *%]') then ceiling = l end
end
T:arm("1 COUNT the probe-count ceiling is gone from " .. CRED, ceiling == nil,
    "nobody chose that number; assert where probes live, not how many: " .. tostring(ceiling))
T:arm("2 COUNT probes are confined to the verdict function instead (structural, no number)", has(CRED, "credential_channel_verdict()"),
    CRED .. " no longer scopes probes; removing the count only deleted coverage")

-- The vacuity baseline must not be the live pool: the selector fixture red
-- whenever the linux ready pool emptied, with no code change.
T:arm("3 POOL the selector is driven through a pinned ledger, not the fleet's", has(SELECTOR, "TILLANDSIAS_PLAN_BIN="),
    SELECTOR .. " does not override TILLANDSIAS_PLAN_BIN")
T:arm("4 POOL that ledger is a fixture the file owns", has(SELECTOR, "_FIXTURE_INDEX") or has(SELECTOR, "fixture-index.yaml"),
    "no fixture ledger in " .. SELECTOR)

-- A hardcoded list that must track a real set: a ninth hook failed at hook
-- INSTALLATION rather than at the stale list.
T:arm("5 LIST the transcribed hook list is gone from " .. HOOKS, not has(HOOKS, "for h in pre-commit-openspec.sh"),
    "a ninth hook will fail here as an installation fault")
T:arm("6 LIST the hook set is derived from install-hooks.sh", has(HOOKS, "install-hooks.sh") and has(HOOKS, 'gmatch("scripts/hooks/'),
    "the coupling is undeclared again")

T:arm("7 NEGATIVE CONTROL the declared vacuity floor is untouched", has(CONTROL, "> 20"),
    "the remedy overreached: a chosen and stated floor must survive in " .. CONTROL)
T:arm("8 NEGATIVE CONTROL that floor still states what it guards against", has(CONTROL, "vacuous") or has(CONTROL, "vacuity"),
    "a stated choice that stops being stated is a snapshot again")
T:finish()
