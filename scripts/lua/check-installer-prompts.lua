-- @trace order:1560-g5d9, spec:host-state-lifecycle
-- @env TILLANDSIAS_INSTALLER_PROMPT_ROOT
-- @read-env TILLANDSIAS_INSTALLER_PROMPT_ROOT
--
-- check-installer-prompts.lua — a RATCHET on interactive prompts in the
-- END-USER installers. Operator ruling 2026-10-08, verbatim: "we do not ask end
-- users to do power user stuff. That's our guideline. An install prompt asking
-- for destructive cases should not be an acceptable case. End user is NOT a
-- power user. No prompts like those, we make all the decisions for them, on
-- their behalf, for their best interests. ... Install should be for END USER
-- (NOT POWER USER) and be a pretty installer, rather than an
-- informational/debugging installer. As frictionless as possible for end users."
--
-- POPULATION: scripts/install.sh, scripts/install-macos.sh,
-- scripts/install-windows.ps1. NOT scripts/uninstall.sh: host-state-lifecycle
-- REQUIRES --uninstall to ask before removing ~/.tillandsias/ (operator ruling
-- on uninstall, 2026-10-08, keeps that ask).
-- A PROMPT is a code line (comments stripped) carrying Read-Host (PowerShell),
-- a `read ... -p` COMMAND (shell; at statement start or after ; & | ( ), or a
-- [y/N] / [Y/n] choice (both). The shell form is command-anchored because prose
-- like "could not read this host's ... guest-shape" matched an unanchored
-- pattern on its first run (install-windows.ps1:437, 2026-10-08).
--
-- FLOOR: scripts/portability/installer-prompt-floor.txt (2 on 2026-10-08: the
-- .wslconfig and Hyper-V prompts in install-windows.ps1, left "for now";
-- removal is 1560-uam3, unscheduled). Above the floor is refused, naming every
-- prompt by file:line; below it passes with a note to lower the floor.
--
-- TILLANDSIAS_INSTALLER_PROMPT_ROOT is the fixture seam
-- (scripts/test-check-installer-prompts.sh).
--
-- Verdicts:
--   ok:installer-prompts:count=<n>:floor=<f>[ — lower the floor ...]   exit 0
--   refused:installer-prompts:count=<n>:floor=<f>:<file:line ...>       exit 1
--   refused:installer-prompts:floor-unreadable:<path>                  exit 1
--   refused:installer-prompts:population-missing:<file>                exit 1
local root_env = env.get("TILLANDSIAS_INSTALLER_PROMPT_ROOT")
local ROOT = (root_env and root_env ~= "") and root_env or nil
local function rooted(rel)
    if ROOT then return ROOT .. "/" .. rel end
    return rel
end

local POP = { "scripts/install.sh", "scripts/install-macos.sh", "scripts/install-windows.ps1" }
local FLOOR_REL = "scripts/portability/installer-prompt-floor.txt"

local ok_floor, floor_text = pcall(fs.read, rooted(FLOOR_REL))
local floor = nil
if ok_floor then
    for line in (floor_text .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" and t:sub(1, 1) ~= "#" then
            floor = tonumber(t:match("^(%d+)$"))
            break
        end
    end
end
if floor == nil then
    log.raw("  why: the ratchet cannot judge without its floor")
    log.raw("  remedy: restore " .. FLOOR_REL .. " with one integer line")
    verdict.emit("refused:installer-prompts:floor-unreadable:" .. FLOOR_REL, 1)
end

-- Strip a trailing comment: from the first `#` at line start or after
-- whitespace (the same approximation the shell decider used).
local function strip_comment(line)
    if line:match("^%s*#") then return "" end
    local at = line:find("%s#")
    if at then return line:sub(1, at) end
    return line
end

-- `read` as a COMMAND whose options include one ending in `p` (-p, -rp, -r -p).
local function shell_read_prompt(line)
    local starts = {}
    local s = line:match("^%s*()read%s")
    if s then starts[#starts + 1] = s end
    for pos in line:gmatch("[;&|(]%s*()read%s") do starts[#starts + 1] = pos end
    for _, pos in ipairs(starts) do
        local rest = line:sub(pos + 4)
        for word in rest:gmatch("%S+") do
            if word:sub(1, 1) ~= "-" then break end
            if word:match("^%-%a*p$") then return true end
        end
    end
    return false
end

local sites = {}
for _, rel in ipairs(POP) do
    local ok_read, content = pcall(fs.read, rooted(rel))
    if not ok_read then
        log.raw("  why: an installer the ratchet covers is not where it was")
        log.raw("  remedy: restore " .. rel .. " or change the population in this decider on purpose")
        verdict.emit("refused:installer-prompts:population-missing:" .. rel, 1)
    end
    local is_ps = rel:match("%.ps1$") ~= nil
    local in_block = false
    local n = 0
    for raw in (content .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local line = raw:gsub("\r$", "")
        if is_ps and line:match("^<#") then in_block = true end
        if in_block then
            if line:find("#>", 1, true) then in_block = false end
        else
            local code = strip_comment(line)
            local hit = false
            if is_ps and code:find("Read-Host", 1, true) then hit = true end
            if (not is_ps) and shell_read_prompt(code) then hit = true end
            if code:find("%[[yY]/[nN]%]") then hit = true end
            if hit then sites[#sites + 1] = rel .. ":" .. n end
        end
    end
end

local count = #sites
if count > floor then
    log.raw("  why: an end-user installer asks the user something (operator ruling 2026-10-08: no prompts; the installer decides)")
    log.raw("  remedy: decide on the user's behalf and remove the prompt; the sites are listed on the verdict line")
    verdict.emit("refused:installer-prompts:count=" .. count .. ":floor=" .. floor .. ":" .. table.concat(sites, " "), 1)
end
if count < floor then
    verdict.emit("ok:installer-prompts:count=" .. count .. ":floor=" .. floor
        .. " — lower the floor in " .. FLOOR_REL .. " to " .. count, 0)
end
verdict.emit("ok:installer-prompts:count=" .. count .. ":floor=" .. floor, 0)
