-- @env TILLANDSIAS_INSTALLER_UNSTABLE_ROOT
-- @read-env TILLANDSIAS_INSTALLER_UNSTABLE_ROOT
-- @trace order:1561-47a8, order:621-2re2, spec:ci-release
--
-- check-installer-unstable-warning.lua — every end-user installer's UNSTABLE
-- branch tells the user something before it installs.
--
-- litmus:smoke-release-channel-shape step 10 used to grep each installer for
-- the literal "UNSTABLE channel". 1561-47a8 (4504c6fd9) gave the Windows
-- installer the soft end-user wording the operator asked for ("!! Preview
-- build: the newest daily version, not yet released as stable."), inside the
-- same `if ($Channel -eq 'unstable')` block, and the grep went red while the
-- property it protected still held. That is the 621-2re2 lesson again: pin
-- the property, not the expression. The soft wording will reach install.sh
-- and install-macos.sh too, and this must not go red when it does.
--
-- THE PROPERTY, per installer:
--   - it has a branch conditioned on the channel being `unstable`
--     (shell: `if ... CHANNEL ... = "unstable"`; PowerShell:
--     `if ($Channel -eq 'unstable')`), and
--   - that branch contains at least one user-facing output statement with a
--     non-empty quoted string (shell say/echo/printf; PowerShell
--     Say/SayWn/SayOk/Write-Host/Write-Warning). Comment lines do not count.
-- The wording is free. A branch that is absent, or that prints nothing, is
-- refused by file:line.
--
-- TILLANDSIAS_INSTALLER_UNSTABLE_ROOT is the fixture seam: a directory holding
-- scripts/ in place of the checkout's.
--
-- Verdicts (one stdout line):
--   ok:installer-unstable-warning:<file>=<lines> ...
--   refused:installer-unstable-warning:<file>:<no-unstable-branch|silent-unstable-branch:line=N|installer-missing>

local SEAM = env.get("TILLANDSIAS_INSTALLER_UNSTABLE_ROOT")
local function at(rel)
    if SEAM ~= nil and SEAM ~= "" then return SEAM .. "/" .. rel end
    return rel
end

local INSTALLERS = {
    "scripts/install.sh",
    "scripts/install-macos.sh",
    "scripts/install-windows.ps1",
}

local SH_IF = [[^\s*if\s.*CHANNEL.*==?\s*["']?unstable["']?]]
local PS_IF = [[^\s*if\s*\(\s*\$Channel\s+-eq\s+['"]unstable['"]\s*\)]]
local SH_END = [[^\s*(fi|else|elif)\b]]
local PS_END = [[^\s*\}]]
local SH_OUT = [[^\s*(say|echo|printf)\s+["']\s*\S]]
local PS_OUT = [[^\s*(Say|SayWn|SayOk|Write-Host|Write-Warning)\s+["']\s*\S]]

local function indent(line)
    return #(string.match(line, "^(%s*)"))
end

-- Returns (warning_line_count, if_line) for the first unstable branch that
-- warns, or (0, if_line) for the last silent one, or (nil, nil) for none.
local function scan(f, src)
    local ps = text.is_match(f, [[\.ps1$]])
    local cond, close, out = SH_IF, SH_END, SH_OUT
    if ps then cond, close, out = PS_IF, PS_END, PS_OUT end
    local lines = text.lines(src)
    local silent = nil
    for n, line in ipairs(lines) do
        if text.is_match(line, cond) then
            local base = indent(line)
            local count = 0
            for m = n + 1, #lines do
                local l = lines[m]
                if text.is_match(l, close) and indent(l) <= base then break end
                if text.is_match(l, out) then count = count + 1 end
            end
            if count > 0 then return count, n end
            silent = n
        end
    end
    if silent ~= nil then return 0, silent end
    return nil, nil
end

local parts = {}
for _, f in ipairs(INSTALLERS) do
    local ok, src = pcall(fs.read, at(f))
    if not ok then
        verdict.emit("refused:installer-unstable-warning:" .. f .. ":installer-missing", 1)
    end
    local count, line = scan(f, src)
    if count == nil then
        verdict.emit("refused:installer-unstable-warning:" .. f .. ":no-unstable-branch", 1)
    elseif count == 0 then
        verdict.emit(
            "refused:installer-unstable-warning:" .. f .. ":silent-unstable-branch:line=" .. line,
            1
        )
    end
    parts[#parts + 1] = f .. "=" .. count
end
verdict.emit("ok:installer-unstable-warning:" .. table.concat(parts, " "), 0)
