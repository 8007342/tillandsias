-- @trace spec:versioning, spec:ci-release, order:914-nkc4, order:1879-5jkt
--
-- check-ledger-distillation.lua: report when the README release ledger has
-- grown past the size its own distillation policy names. PORTED from
-- scripts/check-ledger-distillation.sh as the carried shell-to-lua item of
-- 1879-5jkt, with the same rule.
--
-- Order 914-nkc4. ADVISORY: every verdict about the ledger exits 0, `due:`
-- included. The policy ("when the table exceeds ~10 rows, distill the oldest
-- rows into the `*Older releases*` line") is written in the release skill and
-- README.md's preamble, and nothing ran it: measured 2026-08-26 at 19 rows,
-- with no row ever distilled. Now something does (scripts/release-preflight.sh).
--
-- STRENGTH: REPORT, NOT BLOCK (the 1218-25z3 ruling): an over-long ledger costs
-- a long README, never a false verdict, and a cut is never refused over table
-- length.
--
-- VERDICTS (stdout, last line):
--   ok:ledger-distillation:<n>-rows:threshold=<t>                   exit 0
--   due:ledger-distillation:<n>-rows:threshold=<t> (advisory)       exit 0
--   skip:ledger-distillation:no-readme:<ref>                        exit 0
--   could-not-run:ledger-distillation:unknown-argument:<arg>        exit 3
--   could-not-run:ledger-distillation:missing-value:<flag>          exit 3
-- The .sh printed `skipped:` and `fail:` with exit 0. A Lua decider ends on a
-- house prefix, so a README that could not be read is `skip:`, and a bad
-- argument, which examines nothing, is `could-not-run:`. `due:` keeps its
-- words and gains the door's ` (advisory)` suffix.
--
-- Usage: tillandsias-plan script run scripts/lua/check-ledger-distillation.lua -- [--ref <ref>] [--threshold <n>]

local NAME = "ledger-distillation"

-- The documented trigger is "~10 rows". The tilde is deliberate in prose and
-- useless in a comparison, so the threshold is pinned here and the runbook
-- points at this file rather than restating a number that would drift.
local threshold = "10"
local ref = "HEAD"

-- An unrecognised argument examines nothing and says so (1218-25z3): silently
-- dropping a typo'd flag answers about a tree nobody asked about. Both flags
-- require their value.
local args = arg or {}
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--ref" or a == "--threshold" then
        if args[i + 1] == nil then
            verdict.emit("could-not-run:" .. NAME .. ":missing-value:" .. a, 3, a .. " needs a value; nothing was examined")
        end
        if a == "--ref" then ref = args[i + 1] else threshold = args[i + 1] end
        i = i + 2
    else
        verdict.emit("could-not-run:" .. NAME .. ":unknown-argument:" .. a, 3,
            "nothing was examined. usage: check-ledger-distillation.lua -- [--ref <ref>] [--threshold <n>]")
    end
end
if not threshold:match("^%d+$") then
    verdict.emit("could-not-run:" .. NAME .. ":missing-value:--threshold", 3, "--threshold must be a non-negative integer")
end
local limit = tonumber(threshold)

-- Read the ref, not the worktree, so the check can be pointed at the tree
-- being cut, and so it has a positive control.
local readme = ""
if ref == "HEAD" and fs.exists("README.md") then
    local okr, body = pcall(fs.read, "README.md")
    readme = (okr and body) or ""
else
    local r = proc.run({ argv = { "git", "show", ref .. ":README.md" }, timeout_ms = 30000 })
    if r.code == 0 then readme = r.stdout or "" end
end
if readme == "" then
    verdict.emit("skip:" .. NAME .. ":no-readme:" .. ref, 0,
        "README.md could not be read at '" .. ref .. "'; nothing was counted. A zero here would mean 'could not look', not 'no rows'.")
end

-- One table row per release or per distilled span. The policy is about table
-- length, so a span counts once however many releases it covers.
local rows, spans = 0, 0
for _, l in ipairs(text.lines(readme)) do
    if l:match("^| v%d") then
        rows = rows + 1
        if l:find("DISTILLED", 1, true) then spans = spans + 1 end
    end
end

if rows > limit then
    log.warn("the README release ledger has " .. rows .. " rows; its own policy distills past " .. limit .. ".")
    log.warn(spans .. " row(s) are already DISTILLED spans.")
    log.warn("Distill the oldest into the '*Older releases*' line (the destination is already there).")
    log.warn("ADVISORY (914-nkc4): it does not block a cut. Table length costs a long README, never a false verdict.")
    verdict.advisory("due:" .. NAME .. ":" .. rows .. "-rows:threshold=" .. limit .. " (advisory)")
end
verdict.emit("ok:" .. NAME .. ":" .. rows .. "-rows:threshold=" .. limit, 0)
