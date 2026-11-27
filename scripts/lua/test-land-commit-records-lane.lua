-- @trace order:2431-2yic, order:2143-z5uj, spec:ci-release
-- @env PATH HOME TMPDIR
--
-- test-land-commit-records-lane.lua — every land commit the queue pushes names the lane it took,
-- as a git trailer, so a lane audit needs no host's run logs.
--
-- WHY (2431-2yic). On 2026-11-27 a design agent counted 14 ledger-only PRs as gated in a week; the
-- plan-only lane (2143-z5uj) had carried them (lane=plan-only in macuahuitl's run logs), but
-- nothing on the land commit or the PR said so, so an audit from anywhere else read it wrongly.
--   1 FULL      a code candidate's land commit carries Lane: full and Gate-Skipped: <n>
--   2 PLAN-ONLY a plan/-only candidate's land commit carries Lane: plan-only
--   3 TRAIN     a two-member land-train commit carries Lane: train
-- Read with `git interpret-trailers --parse`, so a line outside the trailer block does not count.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-commit-records-lane.lua
-- Verdict: ok:land-commit-records-lane:<n> arms | violation:...

local fixture = require "common.fixture"
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-commit-records-lane")
for _, t in ipairs({ "git", "jq" }) do
    if not fixture.which(t) then T:skip("no-" .. t .. " — every arm drives the queue with it") end
end
local L = LQ.new(T)
local has = LQ.has

local function trailers(S)
    return L:must("cd " .. LQ.q(S.WORK) .. " && git fetch -q origin && git log -1 --format=%B origin/linux-next | git interpret-trailers --parse")
end

local S = L:scaffold("full")
L:candidate(S, "4001-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/4001-aaaa" } })
L:gate(S, "exit 0\n")
local out = L:run_queue(S)
local tr = trailers(S) or ""
T:arm("1 FULL a code candidate's land commit carries Lane: full and Gate-Skipped", has(out, "land:1 ") and has(tr, "Lane: full") and tr:find("Gate%-Skipped: %d+") ~= nil, "trailers=[" .. tr .. "] " .. out:sub(-200))

S = L:scaffold("plan")
L:candidate(S, "4002-bbbb", "plan/index.d/x.yaml", "x: 1\n")
L:prs(S, { { 2, "work/4002-bbbb" } })
L:gate(S, "exit 0\n")
out = L:run_queue(S)
tr = trailers(S) or ""
T:arm("2 PLAN-ONLY a plan/-only candidate's land commit carries Lane: plan-only", has(out, "lane=plan-only") and has(tr, "Lane: plan-only"), "trailers=[" .. tr .. "] " .. out:sub(-200))

S = L:scaffold("train")
L:candidate(S, "4003-cccc", "c.txt", "C")
L:candidate(S, "4004-dddd", "d.txt", "D")
L:prs(S, { { 3, "work/4003-cccc" }, { 4, "work/4004-dddd" } })
L:gate(S, "exit 0\n")
out = L:run_queue(S, { BATCH_K = "2" })
tr = trailers(S) or ""
local head = L:must("cd " .. LQ.q(S.WORK) .. " && git log -1 --format=%s origin/linux-next") or ""
T:arm("3 TRAIN a land-train commit carries Lane: train", head:find("^land%-train") ~= nil and has(tr, "Lane: train"), "subject=[" .. text.trim(head) .. "] trailers=[" .. tr .. "] " .. out:sub(-200))
T:finish()
