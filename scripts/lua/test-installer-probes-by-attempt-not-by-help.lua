-- @trace spec:ci-release, order:1323-5taw, order:1565-qtuk, order:2367-d5gx
--
-- test-installer-probes-by-attempt-not-by-help.lua — install-windows.ps1 decides whether the tray
-- supports --reset-state by ATTEMPTING it, never by reading --help: v56.9.20.1's headless advertised
-- the flag and refused it with exit 2. Judged on the source with comments stripped, because both files
-- quote the forbidden idiom. That the real block REJECTS such a liar is executed in
-- test-installer-provisions-once.lua, arm 4. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installer-probes-by-attempt-not-by-help.lua
-- Verdict: ok:installer-probes-by-attempt-not-by-help:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("installer-probes-by-attempt-not-by-help")
local SRC = "scripts/install-windows.ps1"
if not fs.exists(SRC) then T:refuse("no-installer", SRC) end

local code = {}
for l in (fs.read(SRC):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do code[#code + 1] = (l:gsub("#.*$", "")) end
-- One judge, so the MUTATION arms are judged the way the arms are.
local function judge(lines)
    local j = { help = 0, match = 0, attempts = 0, guarded = 0, exit = 0, rule = 0 }
    local function count(k, hit) if hit then j[k] = j[k] + 1 end end
    for _, l in ipairs(lines) do
        count("help", l:find("%$%a*Help[^=]*=.*%-%-help"))
        count("match", l:find("match.*%-%-reset%-state"))
        count("attempts", l:find("cmd%.exe /c .*%-%-reset%-state"))
        count("guarded", l:find("TILLANDSIAS_DESTRUCTIVE_RESET_OK=0.*%-%-reset%-state"))
        count("exit", l:find("^%s*%$ResetExit *= *%$LASTEXITCODE"))
        count("rule", l:find("%$HasResetState *= *%(%$ResetExit %-ne 2%)"))
    end
    return j
end
local j = judge(code)
T:arm("1 no --help capture feeds the decision", j.help == 0, j.help)
T:arm("1 the decision is not a pattern match on the flag's name", j.match == 0, j.match)
-- Cardinality, not presence: the lines that mention an attempt outlive the attempt.
T:arm("2 exactly one --reset-state attempt", j.attempts == 1, j.attempts)
T:arm("2 and no separate guarded one, which would provision twice", j.guarded == 0, j.guarded)
T:arm("3 the decision is the attempt's exit code, and only 2 means unsupported", j.exit == 1 and j.rule == 1, j.exit .. "/" .. j.rule)

local function with(extra)
    local t = {}
    for i, l in ipairs(code) do t[i] = l end
    for _, l in ipairs(extra) do t[#t + 1] = l end
    return judge(t)
end
j = with{ '$ResetHelp = & cmd.exe /c "`"$InstalledExe`" --help 2>&1"', [[$HasResetState = ($ResetHelp -join "`n") -match '--reset-state']] }
T:arm("4 MUTATION the pre-fix --help probe fails arm 1 twice", j.help == 1 and j.match == 1, j.help .. "/" .. j.match)
j = with{ [[& cmd.exe /c "set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0&& `"$InstalledExe`" --reset-state"]] }
T:arm("4 MUTATION the guarded second probe fails arm 2 twice", j.attempts == 2 and j.guarded == 1, j.attempts .. "/" .. j.guarded)

T:finish()
