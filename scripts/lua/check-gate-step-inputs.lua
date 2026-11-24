-- @trace order:2157-ginp
--
-- check-gate-step-inputs.lua — every gate step's recorded STEP_READS still
-- names paths that exist.
--
-- ORDER 2157-ginp (build speed): each scripts/gate-steps.d/*.step records the
-- paths it reads in STEP_READS. They are RECORDED ONLY: nothing skips a step on
-- them yet, because skipping a check whose inputs did not change is a scope
-- reduction the operator rules on. A record that is never read rots without a
-- sound, and the day the skip is ruled in, a rotted record would skip a step
-- whose real input changed. So this asks the one thing a record must keep true
-- before it is trusted: every path it names exists (a `dir/**` entry needs
-- `dir`), and every step has a record.
--
-- Exactly one verdict line:
--   ok:gate-step-inputs:<steps>:<paths>
--   violation:gate-step-inputs:<n>-problem(s)   (rc 1; each named on stderr)
-- Usage: tillandsias-plan script run scripts/lua/check-gate-step-inputs.lua [--root DIR]

local root = "."
local i = 1
while arg and arg[i] do
    if arg[i] == "--root" then root = arg[i + 1] or "."; i = i + 2 else i = i + 1 end
end
local DIR = root .. "/scripts/gate-steps.d"

local names = {}
for _, f in ipairs(fs.list(DIR) or {}) do
    if f:match("%.step$") then names[#names + 1] = f end
end
table.sort(names)
if #names == 0 then
    verdict.emit("violation:gate-step-inputs:no-steps", 1, "  no scripts/gate-steps.d/*.step under " .. root)
end

local problems, paths = 0, 0
local function bad(msg) problems = problems + 1; log.raw("  " .. msg) end

for _, n in ipairs(names) do
    local body = fs.read(DIR .. "/" .. n) or ""
    local rec = body:match('\nSTEP_READS="([^"]*)"') or body:match('^STEP_READS="([^"]*)"')
    if not rec then
        bad(n .. ": no STEP_READS record")
    elseif not rec:match("%S") then
        bad(n .. ": STEP_READS is empty")
    else
        for p in rec:gmatch("%S+") do
            paths = paths + 1
            local want = p:gsub("/%*%*$", "")
            if not fs.exists(root .. "/" .. want) then
                bad(n .. ": STEP_READS names " .. p .. ", which does not exist")
            end
        end
    end
end

if problems > 0 then
    log.raw("  remedy: correct the STEP_READS line of each step named above to the paths it reads now")
    verdict.emit("violation:gate-step-inputs:" .. problems .. "-problem(s)", 1)
end
verdict.emit("ok:gate-step-inputs:" .. #names .. ":" .. paths, 0)
