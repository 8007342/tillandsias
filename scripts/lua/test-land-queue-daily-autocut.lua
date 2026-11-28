-- @trace order:2432-ik2d, order:2174-dail, order:2429-u3rp, spec:ci-release
-- @env PATH HOME TMPDIR
--
-- test-land-queue-daily-autocut.lua — an idle land queue cuts the daily full proof itself when the
-- newest one is stale or absent, and says so loudly; it never cuts one while work is waiting.
--
-- WHY (2432-ik2d). A proof older than DAILY_MAX_AGE_S turns every land gate FULL, and only a manual
-- `land-queue.sh --daily-full` cut one (macuahuitl, at irregular hours). A day without one silently
-- froze the scoped tier 2429-u3rp unlocked. Crons are operator-only, so the queue cuts it, on an
-- empty queue only.
--   1 STALE    no proof, empty queue: the run gates trunk, publishes refs/attest/daily-full/<epoch>
--              at trunk's tip, and prints a daily-full:auto line naming why (red on trunk)
--   2 FRESH    a fresh proof, empty queue: no new proof
--   3 BUSY     no proof, one candidate: the candidate lands and no proof is cut
--   4 RED      a red daily run newer than the proof: no auto-cut (a red needs a human, not a retry)
--   5 OFF      TILLANDSIAS_LAND_QUEUE_DAILY_AUTO=0: no proof
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-daily-autocut.lua
-- Verdict: ok:land-queue-daily-autocut:<n> arms | violation:...

local fixture = require "common.fixture"
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-queue-daily-autocut")
for _, t in ipairs({ "git", "jq" }) do
    if not fixture.which(t) then T:skip("no-" .. t .. " — every arm drives the queue with it") end
end
local L = LQ.new(T)
local has = LQ.has
local AUTO = { TILLANDSIAS_LAND_QUEUE_DAILY_AUTO = "1" }

local function proofs(S, ns)
    local o = L:git(S, "ls-remote", "origin", "refs/attest/" .. (ns or "daily-full") .. "/*")
    local n, tip = 0, nil
    for sha in (o or ""):gmatch("(%x+)%s+refs/") do n = n + 1; tip = sha end
    return n, tip
end
local function push_attest(S, ns, age_s)
    L:must("cd " .. LQ.q(S.WORK) .. " && git push -q origin \"origin/linux-next:refs/attest/" .. ns .. "/$(( $(date -u +%s) - " .. age_s .. " ))\"")
end

-- ARM 1: stale (no proof at all) and idle.
local S = L:scaffold("stale")
L:prs(S, {})
L:gate(S, "exit 0\n")
local out = L:run_queue(S, { extra = AUTO })
local n, tip = proofs(S)
local trunk = text.trim(L:git(S, "rev-parse", "origin/linux-next"))
T:arm("1 STALE an idle queue with no proof cuts one at trunk's tip", n == 1 and tip == trunk, "proofs=" .. n .. " tip=" .. tostring(tip) .. " trunk=" .. trunk .. " " .. out:sub(-400))
T:arm("1 STALE and says why, loudly", has(out, "daily-full:auto") and has(out, "no-daily-run"), out:sub(-400))

-- ARM 2: fresh proof, idle.
S = L:scaffold("fresh")
L:prs(S, {})
L:gate(S, "exit 0\n")
push_attest(S, "daily-full", 60)
out = L:run_queue(S, { extra = AUTO })
n = proofs(S)
T:arm("2 FRESH a fresh proof is not re-cut", n == 1 and not has(out, "daily-full:auto"), "proofs=" .. n .. " " .. out:sub(-300))

-- ARM 3: no proof, but a candidate waiting.
S = L:scaffold("busy")
L:candidate(S, "3001-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/3001-aaaa" } })
L:gate(S, "exit 0\n")
out = L:run_queue(S, { extra = AUTO })
n = proofs(S)
T:arm("3 BUSY a run with a candidate lands it and cuts no proof", n == 0 and has(out, "land:1 ") and not has(out, "daily-full:auto"), "proofs=" .. n .. " " .. out:sub(-300))

-- ARM 4: a red daily run newer than the newest proof.
S = L:scaffold("red")
L:prs(S, {})
L:gate(S, "exit 0\n")
push_attest(S, "daily-full", 90000)
push_attest(S, "daily-red", 3600)
out = L:run_queue(S, { extra = AUTO })
n = proofs(S)
T:arm("4 RED a newer red daily run is not retried by the idle queue", n == 1 and not has(out, "daily-full:auto:cutting"), "proofs=" .. n .. " " .. out:sub(-300))

-- ARM 5: switched off.
S = L:scaffold("off")
L:prs(S, {})
L:gate(S, "exit 0\n")
out = L:run_queue(S, { extra = { TILLANDSIAS_LAND_QUEUE_DAILY_AUTO = "0" } })
n = proofs(S)
T:arm("5 OFF DAILY_AUTO=0 cuts nothing", n == 0, "proofs=" .. n .. " " .. out:sub(-300))
T:finish()
