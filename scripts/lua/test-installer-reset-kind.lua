-- @trace spec:host-state-lifecycle, order:1559-sqzp, order:1437-3iux, order:2205-cepb
--
-- test-installer-reset-kind.lua — PORTED from test-installer-reset-kind.sh
-- (2205-cepb), same five arms, same lines. install-windows.ps1 runs the SOFT
-- reset and ONLY the SOFT reset, never prompts about it, and prints no
-- power-user text (operator ruling 2026-10-08: "End user is NOT a power user
-- ... SOFT reset is the default only and forever").
--
-- Asserted over the installer's CODE (comments stripped), and over its RESET
-- PATH (from `# BEGIN-RESET-PROBE` to the Installed-Software registration):
--   1 no HARD anywhere: no --reset-guest, --approve-hard-reset, -HardReset,
--     TILLANDSIAS_INSTALL_RESET, TILLANDSIAS_HARD_RESET_APPROVED or reset-kind
--     chooser (Get-TillandsiasResetPlan)
--   2 the reset is exactly one `--reset-state < NUL` (SOFT, stdin from NUL)
--   3 no Read-Host on the reset path
--   4 no output statement on the reset path names a flag, a variable, SOFT,
--     HARD, a reset or a probe
--   5 the tray's own reset log is not echoed into the installer's output
-- Pre-fix (#247 at 0d1c6a852): FAILS — a HARD kind, a Read-Host prompt and a
-- reset-kind first line.
--
-- Verdict: ok:installer-reset-kind:5 arms | fail:installer-reset-kind:<n>

local SRC = "scripts/install-windows.ps1"
local fails = 0
local function pass(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); fails = fails + 1 end

-- PowerShell comments: whole-line `#` and trailing ` # ...` (the awk
-- `sub(/(^|[[:space:]])#.*/, "")`: the whitespace before the # goes too).
local function strip(l)
    if l:sub(1, 1) == "#" then return "" end
    local i = l:find("%s#")
    if i then return l:sub(1, i - 1) end
    return l
end

local lines = text.lines(fs.read(SRC) or "")

-- Code: block comments (<# ... #>, the help header) dropped, then stripped.
local code, inblk = {}, false
for _, l in ipairs(lines) do
    if l:sub(1, 2) == "<#" then inblk = true end
    if inblk then
        if l:find("#>", 1, true) then inblk = false end
    else
        code[#code + 1] = strip(l)
    end
end
local code_s = table.concat(code, "\n")

local nb, reg = 0, 0
for _, l in ipairs(lines) do
    if l == "# BEGIN-RESET-PROBE" then nb = nb + 1 end
    if l:find("Installed-Software registration", 1, true) then reg = reg + 1 end
end
if nb ~= 1 or reg < 1 then
    verdict.emit("fail:installer-reset-kind:reset-path-markers:probe=" .. nb .. ":registration=" .. reg, 1)
end

local rp, f = {}, false
for _, l in ipairs(lines) do
    if l == "# BEGIN-RESET-PROBE" then f = true end
    if f and l:find("Installed-Software registration", 1, true) then break end
    if f then rp[#rp + 1] = strip(l) end
end

-- 1 — no HARD anywhere in the installer's code.
local hard_hits = ""
for _, tok in ipairs({ "--reset-guest", "--approve-hard-reset", "HardReset", "TILLANDSIAS_INSTALL_RESET",
        "TILLANDSIAS_HARD_RESET_APPROVED", "Get-TillandsiasResetPlan" }) do
    if code_s:find(tok, 1, true) then hard_hits = hard_hits .. " " .. tok end
end
if hard_hits == "" then pass("1 no HARD path in the installer") else bad("1 HARD path present:" .. hard_hits) end

-- 2 — exactly one SOFT reset call, stdin from NUL.
local soft = 0
for _, l in ipairs(rp) do if l:find("--reset-state < NUL", 1, true) then soft = soft + 1 end end
if soft == 1 then pass("2 one --reset-state call, stdin from NUL") else bad("2 SOFT call count=" .. soft) end

-- 3 — the reset path never prompts.
local prompt = false
for _, l in ipairs(rp) do if l:lower():find("read-host", 1, true) then prompt = true end end
if prompt then bad("3 a Read-Host on the reset path") else pass("3 no prompt on the reset path") end

-- 4 — no power-user text in the reset path's output statements. Variable
-- NAMES are not visible text, so $Identifiers are dropped before matching.
local noisy = {}
for _, l in ipairs(rp) do
    local p = " " .. l
    local says = false
    for _, w in ipairs({ "Say", "SayOk", "SayWn", "Write%-Host", "Die" }) do
        if p:find("%s" .. w .. "%s") then says = true end
    end
    if says then
        local s = l:gsub("%$[A-Za-z_]+", "")
        local low = s:lower()
        local hit = s:find("%-%-[a-zA-Z]") or s:find("TILLANDSIAS_", 1, true)
        for _, w in ipairs({ "soft", "hard", "reset", "probe", "tillandsias_" }) do
            if low:find(w, 1, true) then hit = true end
        end
        if low:find("%-%-[a-z]") then hit = true end
        if hit and not s:find("Get-Content", 1, true) then noisy[#noisy + 1] = s end
    end
end
if #noisy == 0 then pass("4 no flag, variable or reset-kind text in the output")
else bad("4 power-user text: " .. table.concat(noisy, "|"):sub(1, 300)) end

-- 5 — the tray's reset log is not echoed into the install.
local echoed = false
for _, l in ipairs(rp) do
    local i = l:find("Get-Content", 1, true)
    while i do
        local rest = l:sub(i + 11)
        local bar = rest:find("|", 1, true)
        if bar then rest = rest:sub(1, bar - 1) end
        if rest:find("$ResetLog", 1, true) then echoed = true end
        i = l:find("Get-Content", i + 1, true)
    end
end
if echoed then bad("5 the tray's reset log is echoed") else pass("5 the tray's reset log stays out of the output") end

if fails ~= 0 then verdict.emit("fail:installer-reset-kind:" .. fails, 1) end
verdict.emit("ok:installer-reset-kind:5 arms", 0)
