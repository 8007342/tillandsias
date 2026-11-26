-- @trace order:1302-7j8p, order:2124-mwzr
--
-- check-gate-step-regimes.lua — every gate step carries a usable SECOND-REGIME
-- record (darwin or msys), so a step green only on its author's regime cannot
-- join the gate. Ported from check-gate-step-regimes.sh (2124-mwzr); the
-- grammar is unchanged.
--
-- WHY: two steps green only on Linux reddened both macOS gates within hours on
-- 2026-09-20. A record is STEP_SECOND_REGIME="<host> <YYYY-MM-DD> <darwin|msys>
-- <verdict>"; a skip:<reason> verdict COUNTS (it is an observation from the
-- other regime, not necessarily a green one). STEP_HOST_STATE, when present,
-- must be keyring or load.
--
-- Usage: tillandsias-plan script run scripts/lua/check-gate-step-regimes.lua [-- <step-dir>]
--   default <step-dir>: scripts/gate-steps.d
-- Grammar (stdout, one verdict line):
--   ^(ok:gate-step-regimes:[0-9]+|violation:gate-step-single-regime:[0-9]+|skip:gate-step-regimes:no-step-dir:.+)$
--   per-step violation lines on stderr.
local DIR = (arg and arg[1] and arg[1] ~= "") and arg[1] or "scripts/gate-steps.d"
local okw, walked = pcall(fs.walk, DIR)
if not okw or not walked then verdict.emit("skip:gate-step-regimes:no-step-dir:" .. DIR, 0) end

local steps = {}
for _, f in ipairs(walked) do
    local rel = f:sub(#DIR + 2)
    if f:sub(1, #DIR + 1) == DIR .. "/" and not rel:find("/", 1, true) and rel:match("%.step$") then
        steps[#steps + 1] = { path = f, name = rel }
    end
end
table.sort(steps, function(a, b) return a.name < b.name end)

-- Every `NAME=` line's value, quotes stripped (2221-vjqb: a step carries a darwin AND an msys record).
local function fields(body, name)
    local all = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local v = line:match("^%s*" .. name .. "=(.*)$")
        if v then all[#all + 1] = (v:gsub('^"', ""):gsub('"$', "")) end
    end
    return all
end

local SECOND = { darwin = true, msys = true }
local missing, malformed, linuxonly, ok = 0, 0, 0, 0
local carrying = { darwin = 0, msys = 0 }
local detail = {}
for _, s in ipairs(steps) do
    local body = fs.read(s.path) or ""
    local hs = fields(body, "STEP_HOST_STATE")[1]
    if hs and hs ~= "keyring" and hs ~= "load" then
        malformed = malformed + 1
        detail[#detail + 1] = "violation:gate-step-host-state:" .. s.name .. ":" .. (hs ~= "" and hs or "empty") .. "-is-not-keyring-or-load"
    else
        local records = fields(body, "STEP_SECOND_REGIME")
        local why, seen = nil, {}
        for _, v in ipairs(records) do
            local host, date_, regime = v:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
            if not host then why = "malformed-record"
            elseif not date_:match("^%d%d%d%d%-%d%d%-%d%d$") then why = "date-not-yyyy-mm-dd"
            elseif not SECOND[regime] then why = "regime-" .. regime .. "-is-not-a-second-regime"
            else seen[regime] = true end
            if why then break end
        end
        if #records == 0 then
            missing = missing + 1
            detail[#detail + 1] = "violation:gate-step-single-regime:" .. s.name
        elseif why then
            if why:match("^regime%-") then linuxonly = linuxonly + 1 else malformed = malformed + 1 end
            detail[#detail + 1] = "violation:gate-step-single-regime:" .. s.name .. ":" .. why
        else
            for r in pairs(seen) do carrying[r] = carrying[r] + 1 end
            ok = ok + 1
        end
    end
end

local bad = missing + malformed + linuxonly
if bad > 0 then
    for _, d in ipairs(detail) do log.raw(d) end
    log.raw("  " .. bad .. " of " .. (bad + ok) .. " gate steps carry no usable second-regime record.")
    log.raw("  why: a step green only on its author's regime is the failure this refuses:")
    log.raw("  two such steps reddened both macOS gates within hours on 2026-09-20.")
    log.raw("  remedy: run the step on a second regime, then add to the .step file:")
    log.raw('    STEP_SECOND_REGIME="<host> <YYYY-MM-DD> <darwin|msys> <verdict>"')
    log.raw("  A step that genuinely cannot run off Linux records skip:<reason> as")
    log.raw("  its verdict, and that COUNTS — the record is an observation from the")
    log.raw("  other regime, not necessarily a green one.")
    verdict.emit("violation:gate-step-single-regime:" .. bad, 1)
end
log.raw("  regimes: darwin=" .. carrying.darwin .. " msys=" .. carrying.msys .. " (steps carrying each; 2221-vjqb)")
verdict.emit("ok:gate-step-regimes:" .. ok, 0)
