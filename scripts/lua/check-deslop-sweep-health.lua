-- @env TILLANDSIAS_DESLOP_LEDGER_DIR
-- @trace order:829-dkuc, order:1106-k2df, order:2400-hwnk
--
-- check-deslop-sweep-health.lua — THE SWEEP'S OWN RITUAL DETECTOR. Ported from the .sh of the same
-- name; every verdict line and exit is unchanged. The .sh's --self-test arms are now
-- scripts/lua/test-deslop-sweep-health.lua.
--
-- Packet 829-dkuc names four rules whose purpose is to stop the de-slop sweep becoming the thing it
-- hunts ("these are not optional, each is computable from the stamp record"; "the step is subject to
-- its own ritual detector, no exemption"). This reads plan/deslop-sweeps.d/*.md (the records
-- scripts/check-deslop-due.sh writes) and computes:
--   KILL RULE        two consecutive sweeps that EXAMINED rows and confirmed nothing =>
--                    red:two-sweeps-zero-confirmed. Sweeps that examined nothing are skipped, not
--                    counted as zero (2026-08-20 sizing note), or a quiet tree retires the reconciler.
--   REFUTATION BAND  over the 4 trailing sweeps, 0% refuted => rubber-stamping; 100% => nothing real.
--   NET-NEGATIVE     a sweep's own diff must delete more than it adds.
--   FILING CAP       at most 5 packets filed per sweep, and it must retract at least as many as it files.
-- It does not run a sweep, delete, retract or write to the ledger: the sweep is the half of 829-dkuc
-- its next_action reserves for an operator-paired session ("PRIORITY IS NOT PERMISSION").
--
-- "CANNOT TELL" IS NOT "HEALTHY", AND THEY GET DIFFERENT EXIT CODES. Every rule needs history the
-- ledger may not have, so an unscoreable rule is NAMED and the run exits 2 (the 1106-k2df shape: a
-- value true about the artefact, "no rule fired", read as the property it names, "healthy").
--
-- ONE RULE HALF IS UNREACHABLE, AND IT IS NAMED RATHER THAN QUIETLY KEPT. red:refutation-rate-
-- degenerate:100 cannot fire in production: four examined sweeps that confirmed nothing trip the KILL
-- RULE at sweep two, and check-deslop-due.sh refuses a record without --examined. Pinned by the
-- fixture's precedence arm and reported upward: dropping it or giving it a reachable meaning is an
-- operator call, alongside the still-open D4.
--
-- Usage: tillandsias-plan script run scripts/lua/check-deslop-sweep-health.lua
--        TILLANDSIAS_DESLOP_LEDGER_DIR=<dir>  fixture seam (same var as the writer)
-- Exit: 0 every applicable rule evaluated and passed (ok:)   1 a rule fired (red:)
--       2 nothing could be scored (unknown:), or usage/infra failure (fail:)

local BAND_WINDOW, FILING_CAP = 4, 5

if (arg or {})[1] and arg[1] ~= "" then verdict.emit("fail:deslop-health:usage: check-deslop-sweep-health.lua (the self-test is scripts/lua/test-deslop-sweep-health.lua)", 2) end
local top = proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.emit("fail:deslop-health:no-repo-root", 2) end
local DIR = env.get("TILLANDSIAS_DESLOP_LEDGER_DIR")
if not DIR or DIR == "" then DIR = ROOT .. "/plan/deslop-sweeps.d" end

-- One record per well-formed DESLOP-SWEEP line under a well-formed "## <ts> <host>" header, with nil
-- for an absent field. Fields are space-split and anchored as check-deslop-due.sh reads them
-- (803-bqte), so a record may grow new fields in any order.
local recs, found = {}, false
local okl, names = pcall(fs.list, DIR)
if okl and names then
    table.sort(names)
    for _, name in ipairs(names) do
        if name:match("%.md$") and name ~= "README.md" then
            found = true
            local ts
            for line in ((fs.read(DIR .. "/" .. name) or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
                if line:sub(1, 3) == "## " then
                    ts = line:match("^## (%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ) [^ ]+$")
                elseif line:find("^DESLOP%-SWEEP:") then
                    local r = { ts = ts }
                    for w in line:gmatch("%S+") do
                        local k, v = w:match("^(%a+)=(%d+)$")
                        if k == "order" then r.ord = tonumber(v)
                        elseif k == "examined" then r.ex = tonumber(v)
                        elseif k == "confirmed" then r.cf = tonumber(v)
                        elseif k == "findings" then r.fi = tonumber(v)
                        elseif k == "retracted" then r.re = tonumber(v)
                        elseif k == "filed" then r.fl = tonumber(v) end
                        local nl = w:match("^net_lines=([-+]?%d+)$")
                        if nl then r.nl = tonumber((nl:gsub("^%+", ""))) end
                    end
                    if r.ts and r.ord then recs[#recs + 1] = r end
                end
            end
        end
    end
end
if not found then verdict.emit("fail:deslop-health:no-ledger-dir:" .. DIR, 2) end
if #recs == 0 then
    verdict.emit("unknown:deslop-health:no-records — the ledger holds no well-formed DESLOP-SWEEP line, so no rule can score. This is NOT a pass.", 2)
end
-- Oldest first by order (sort -k3,3n); a tie keeps the order the files gave it.
for i, r in ipairs(recs) do r.i = i end
table.sort(recs, function(a, b) if a.ord ~= b.ord then return a.ord < b.ord end; return a.i < b.i end)
local total = #recs

-- ── KILL RULE: only sweeps with examined>0 score; two consecutive at confirmed=0 retire it ─────
local n_scoring, streak, worst, prev = 0, 0, nil, nil
for _, r in ipairs(recs) do
    if r.ex and r.ex > 0 and r.cf then
        n_scoring = n_scoring + 1
        if r.cf == 0 then
            streak = streak + 1
            if streak >= 2 then worst = tostring(prev) .. "," .. r.ts end
        else
            streak = 0
        end
        prev = r.ts
    end
end
if worst then
    verdict.emit("red:two-sweeps-zero-confirmed:" .. worst .. " — two consecutive sweeps examined rows and confirmed nothing; 829-dkuc's kill rule sets that packet to obsoleted with reason deslop:ritual:self, no exemption", 1)
end

local function list(pred, fmt)
    local t = {}
    for _, r in ipairs(recs) do if pred(r) then t[#t + 1] = fmt(r) end end
    return table.concat(t, ",")
end
-- ── NET-NEGATIVE DIFF ──────────────────────────────────────────────────────────────────────
local bad_net = list(function(r) return r.nl and r.nl >= 0 end, function(r) return r.ord .. "=" .. r.nl end)
if bad_net ~= "" then verdict.emit("red:net-positive-diff:" .. bad_net .. " — a sweep must delete more than it adds (excluding litmus and scripts/check-*)", 1) end
-- ── FILING CAP ─────────────────────────────────────────────────────────────────────────────
local over = list(function(r) return r.fl and r.fl > FILING_CAP end, function(r) return r.ord .. "=filed" .. r.fl end)
if over ~= "" then verdict.emit("red:filing-cap-exceeded:" .. over .. " — at most " .. FILING_CAP .. " packets per sweep", 1) end
local under = list(function(r) return r.fl and r.re and r.fl > r.re end, function(r) return r.ord .. "=filed" .. r.fl .. "/retracted" .. r.re end)
if under ~= "" then
    verdict.emit("red:filed-exceeds-retracted:" .. under .. " — a sweep must retract at least as many rows as it files, or it is a net filer wearing a reducer's name", 1)
end

-- ── REFUTATION BAND ────────────────────────────────────────────────────────────────────────
local band = {}
for _, r in ipairs(recs) do if r.fi and r.cf then band[#band + 1] = r end end
while #band > BAND_WINDOW do table.remove(band, 1) end
local band_n, sum_f, sum_c, rate = #band, 0, 0, "-"
for _, r in ipairs(band) do sum_f = sum_f + r.fi; sum_c = sum_c + r.cf end
if band_n >= BAND_WINDOW and sum_f > 0 then
    rate = (sum_f - sum_c) * 100 // sum_f
    if rate == 0 then
        verdict.emit("red:refutation-rate-degenerate:0 — over " .. BAND_WINDOW .. " trailing sweeps every finding was confirmed; a finder that is never wrong is not being falsified", 1)
    end
    if rate == 100 then
        verdict.emit("red:refutation-rate-degenerate:100 — over " .. BAND_WINDOW .. " trailing sweeps nothing was confirmed; the finder is producing nothing real", 1)
    end
end

-- ── WHAT COULD NOT BE SCORED: named individually; a rule with no data must not hide in a pass ──
local un = {}
if n_scoring < 2 then un[#un + 1] = "kill-rule(needs-2-scoring-sweeps-have-" .. n_scoring .. ")" end
if band_n < BAND_WINDOW then un[#un + 1] = "refutation-band(needs-" .. BAND_WINDOW .. "-with-findings-have-" .. band_n .. ")" end
local has_nl, has_fl = false, false
for _, r in ipairs(recs) do has_nl = has_nl or r.nl ~= nil; has_fl = has_fl or r.fl ~= nil end
if not has_nl then un[#un + 1] = "net-negative(no-record-carries-net_lines)" end
if not has_fl then un[#un + 1] = "filing-cap(no-record-carries-filed)" end
if #un > 0 then
    verdict.emit("unknown:deslop-health:sweeps=" .. total .. " unscoreable:" .. table.concat(un, ",") .. " — no rule fired, but these could not be evaluated; that is not a pass", 2)
end
verdict.emit("ok:deslop-health:sweeps=" .. total .. " scoring=" .. n_scoring .. " refutation=" .. tostring(rate) .. "% — every applicable rule evaluated and passed", 0)
