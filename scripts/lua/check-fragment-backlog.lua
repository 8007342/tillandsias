-- @env TILLANDSIAS_FRAGMENT_BACKLOG_THRESHOLD
-- @trace spec:methodology-accountability
-- @trace order:941-trcf, order:1577-568c
--
-- check-fragment-backlog.lua — compaction-cadence advisory (941-trcf A1),
-- PORTED from check-fragment-backlog.sh with the same two lines, the
-- advisory one now ending ` (advisory)` as verdict.advisory requires. It pays
-- 1577-568c's shell-to-lua item, and shows an `advisory:` decider ports
-- through verdict.advisory without a new verdict class.
--
-- WHY THIS EXISTS, with the numbers that earned it. Every heavy
-- tillandsias-plan invocation overlays plan/index.d/ onto the base ledger,
-- and that overlay cost is LINEAR IN THE BACKLOG: measured 2026-08-30 on
-- macuahuitl, 338 accumulated fragments put ~160ms of overlay into every
-- ~258ms heavy load, and one full ./build.sh --check performs ~88 such
-- loads — compacting the backlog halved the warm gate (118s -> 56s).
--
-- The threshold is 50: ~2s of gate cost, far below noise, but early enough
-- that whoever sees the line can fold before the backlog is 338 again.
--
-- ADVISORY, NOT A GATE (the 751-i9mb terms): a grown backlog is news for the
-- next coordination cycle, not a build break. Compaction belongs to a cycle
-- that can gate, commit and push the fold as one unit.
--
--   ok:fragment-backlog:<n><=<threshold>                         exit 0
--   advisory:fragment-backlog:<n>><threshold> — <remedy> (advisory)  exit 0
--
-- A missing plan/index.d is a fine, empty backlog: a fully compacted tree is
-- the goal state, not an error.

local FRAG_DIR = "plan/index.d"
local threshold = tonumber(env.get("TILLANDSIAS_FRAGMENT_BACKLOG_THRESHOLD") or "") or 50

-- Top-level *.yaml only, as the shell glob counted; fs.walk is recursive.
local count = 0
local ok_walk, walked = pcall(fs.walk, FRAG_DIR)
if ok_walk then
    for _, f in ipairs(walked) do
        local rel = f:sub(#FRAG_DIR + 2)
        if not rel:find("/", 1, true) and rel:match("%.yaml$") then count = count + 1 end
    end
end

if count > threshold then
    verdict.advisory(string.format(
        "advisory:fragment-backlog:%d>%d — every heavy plan load re-overlays all %d fragments (~0.5ms each, ~88 loads per gate); run 'tillandsias-plan compact' in a cycle that can gate+commit+push the fold (941-trcf) (advisory)",
        count, threshold, count))
end
verdict.ok("fragment-backlog", count .. "<=" .. threshold)
