-- @env TILLANDSIAS_INSTALLER_OUTPUT_ROOT
-- @read-env TILLANDSIAS_INSTALLER_OUTPUT_ROOT
-- @trace order:1561-9f4x, order:1561-47a8, spec:host-state-lifecycle
--
-- check-installer-end-user-output.lua — the END-USER installers print only
-- end-user lines. Operator ruling 2026-10-08, verbatim: "we do not need to print
-- any power user messages during install, at all. Install should be for END USER
-- (NOT POWER USER) and be a pretty installer, rather than an
-- informational/debugging installer. As frictionless as possible for end users."
--
-- Written in Lua from the start: 1561-47a8's first draft was a new
-- scripts/check-*.sh, which the shell ratchet refuses (a new .sh decider adds to
-- the shell-to-Lua backlog the carried obligation burns down).
--
-- A DIAGNOSTIC OUTPUT LINE is a user-facing output statement whose text names a
-- --flag, a TILLANDSIAS_* variable, a URL, a channel or a base. Output
-- statements: Say / SayOk / SayWn / Write-Host / Die in PowerShell; say / die /
-- echo / printf in shell. Comments are stripped first (a `#` at the start of a
-- line or after whitespace; PowerShell `<# ... #>` blocks whole). Two
-- exemptions, both visible in the source:
--   - a line marked `# power-user-only`: reachable only when a power user passes
--     a bad flag (usage and argument errors), never on the normal path;
--   - a region between `# BEGIN-PENDING-1560-UAM3` and `# END-PENDING-1560-UAM3`:
--     the .wslconfig and Hyper-V prompt blocks the operator left "for now";
--     their removal (1560-uam3) removes the markers and the text with them.
-- Diagnostics belong in the installer's log file, shown by path on failure.
--
-- FLOORS: scripts/portability/installer-end-user-output-floor.txt, one
-- "<installer> <count>" line each. Above the floor is refused, naming every
-- line by file:line; below it passes with a note to lower the floor. Each
-- platform slice of 1561-9f4x drops its installer to 0.
--
-- TILLANDSIAS_INSTALLER_OUTPUT_ROOT is the fixture seam
-- (scripts/lua/test-check-installer-end-user-output.lua): a directory holding
-- scripts/ and scripts/portability/ in place of the checkout's.
--
-- Verdicts (one stdout line):
--   ok:installer-end-user-output:<file>=<n> ...
--   refused:installer-end-user-output:<file>:count=<n>:floor=<f>:<file:line ...>
--   refused:installer-end-user-output:floor-file-missing|floor-unreadable|installer-missing:<x>

local SEAM = env.get("TILLANDSIAS_INSTALLER_OUTPUT_ROOT")
local function at(rel)
    if SEAM ~= nil and SEAM ~= "" then return SEAM .. "/" .. rel end
    return rel
end

local FLOORS = "scripts/portability/installer-end-user-output-floor.txt"
local ok_floors, floors_text = pcall(fs.read, at(FLOORS))
if not ok_floors then
    verdict.emit("refused:installer-end-user-output:floor-file-missing:" .. FLOORS, 1)
end

local PS_OUT = [[(^|[\s;{(])(Say|SayOk|SayWn|Write-Host|Die)\s]]
local SH_OUT = [[(^|[\s;{(|&])(say|die|echo|printf)\s]]
local DIAG = [[--[a-z]|TILLANDSIAS_|https?:|[Cc]hannel|base:]]

-- The line with its comment removed: from the first `#` that starts the line
-- or follows whitespace (the awk the first draft carried, kept exactly).
local function strip_comment(line)
    local i = 1
    while true do
        local j = string.find(line, "#", i, true)
        if j == nil then return line end
        if j == 1 or string.find(string.sub(line, j - 1, j - 1), "%s") then
            return string.sub(line, 1, j - 1)
        end
        i = j + 1
    end
end

local function diagnostic_lines(f, src)
    local ps = text.is_match(f, [[\.ps1$]])
    local hits = {}
    local blk, pend = false, false
    for n, line in ipairs(text.lines(src)) do
        if text.is_match(line, [[^<#]]) then blk = true end
        if blk then
            if string.find(line, "#>", 1, true) then blk = false end
        elseif text.is_match(line, [[#\s*BEGIN-PENDING-1560-UAM3]]) then
            pend = true
        elseif text.is_match(line, [[#\s*END-PENDING-1560-UAM3]]) then
            pend = false
        elseif not pend and not text.is_match(line, [[#\s*power-user-only]]) then
            local code = strip_comment(line)
            local is_out = ps and text.is_match(code, PS_OUT) or (not ps and text.is_match(code, SH_OUT))
            if is_out and text.is_match(code, DIAG) then
                hits[#hits + 1] = f .. ":" .. n
            end
        end
    end
    return hits
end

local refusals, summary = {}, {}
for _, raw in ipairs(text.lines(floors_text)) do
    local l = text.trim(raw)
    if l ~= "" and string.sub(l, 1, 1) ~= "#" then
        local f, floor = string.match(l, "^(%S+)%s+(%S+)$")
        if f == nil or not string.match(floor, "^%d+$") then
            verdict.emit("refused:installer-end-user-output:floor-unreadable:" .. (f or l), 1)
        end
        local ok_src, src = pcall(fs.read, at(f))
        if not ok_src then
            verdict.emit("refused:installer-end-user-output:installer-missing:" .. f, 1)
        end
        local hits = diagnostic_lines(f, src)
        local count, fl = #hits, tonumber(floor)
        if count > fl then
            refusals[#refusals + 1] = "refused:installer-end-user-output:" .. f .. ":count=" .. count
                .. ":floor=" .. fl .. ":" .. table.concat(hits, " ")
        elseif count < fl then
            summary[#summary + 1] = f .. "=" .. count .. "<floor=" .. fl .. "(lower-the-floor)"
        else
            summary[#summary + 1] = f .. "=" .. count
        end
    end
end

if #refusals > 0 then
    for i = 2, #refusals do log.raw(refusals[i]) end
    log.raw("  why: an end-user installer prints power-user or diagnostic text (operator ruling 2026-10-08)")
    log.raw("  remedy: write the detail to the installer's log and print a plain end-user line; mark a usage error # power-user-only")
    verdict.emit(refusals[1], 1)
end
verdict.emit("ok:installer-end-user-output:" .. table.concat(summary, " "), 0)
