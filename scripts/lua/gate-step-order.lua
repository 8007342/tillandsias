-- @env TILLANDSIAS_TIMING_LOG
-- @read-env TILLANDSIAS_TIMING_LOG
-- @trace order:2430-ffst
--
-- gate-step-order.lua — derive the fail-fast DISPATCH order for the gate-step pool from the timing log.
-- A gate step's phase record is the slug of "$STEP_DESC..." (build.sh _step + _phase_emit_timing:
-- lowercase, non-alphanumerics to "-", trimmed, at most 64 chars). For each gate-steps.d step whose
-- slug has records: score = red rate / mean seconds, so the step most likely to red soonest starts first.
-- Steps with no red in the log are left out (they keep filename order after the listed ones).
--
-- Usage: TILLANDSIAS_TIMING_LOG=<log> tillandsias-plan script run --helper scripts/lua/gate-step-order.lua > <order-file>
--        then TILLANDSIAS_GATE_STEP_ORDER=<order-file> ./build.sh --check
-- Output: one step basename per line, best first; a `# score reds/runs mean_s` comment follows each.

local log_path = env.get("TILLANDSIAS_TIMING_LOG")  -- a declared read root (@read-env), so it may live outside the repo
if not log_path or log_path == "" then error("gate-step-order: name the timing log (TILLANDSIAS_TIMING_LOG)") end
local okr, body = pcall(fs.read, log_path)
if not okr or not body then error("gate-step-order: cannot read the timing log at " .. log_path .. ": " .. tostring(body)) end

local function slug(s)
    s = s:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return s:sub(1, 64)
end

-- slug -> step basename, from every step's STEP_DESC
local by_slug = {}
for _, p in ipairs(fs.list("scripts/gate-steps.d")) do
    local name = p:match("([^/\\]+%.step)$")
    if name then
        local body = fs.read("scripts/gate-steps.d/" .. name)
        local desc = body:match('\nSTEP_DESC="([^"]*)"') or body:match('^STEP_DESC="([^"]*)"')
        if desc then by_slug[slug(desc .. "...")] = name end
    end
end

local stats = {}
for _, line in ipairs(text.lines(body)) do
    local ok, r = pcall(json.parse, line)
    if ok and type(r) == "table" and r.step and by_slug[r.step] and (r.phase == "build" or r.phase == "build-span") then
        local s = stats[r.step] or { n = 0, red = 0, ms = 0 }
        s.n = s.n + 1
        s.ms = s.ms + (tonumber(r.duration_ms) or 0)
        if tostring(r.exit) ~= "0" then s.red = s.red + 1 end
        stats[r.step] = s
    end
end

local rows = {}
for sl, s in pairs(stats) do
    if s.red > 0 then
        local mean = math.max(s.ms / s.n / 1000, 0.1)
        rows[#rows + 1] = { name = by_slug[sl], score = (s.red / s.n) / mean, s = s, mean = mean }
    end
end
table.sort(rows, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.name < b.name end)
for _, r in ipairs(rows) do
    out.line(r.name)
    out.line(("# %.5f %d/%d %.1f"):format(r.score, r.s.red, r.s.n, r.mean))
end
