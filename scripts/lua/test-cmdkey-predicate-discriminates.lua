-- @env PATH HOME OS SYSTEMROOT
-- @trace order:1004-vsh2, order:1055-6yp8, order:2343-3ch4
--
-- test-cmdkey-predicate-discriminates.lua — the smoke runbook's credential-presence predicate
-- can be FALSE. Ported from the .sh of the same name (2343-3ch4). `cmdkey /list:<target>` echoes
-- the queried name in its header even when no such credential exists, so matching the name was
-- true for every target: the post-delete check threw on every run, and the delete's guard never
-- guarded. Windows arms run the SHIPPED helper, cut from the runbook, on a target that does not
-- exist; they only list, nothing is stored or deleted.
--
--   1 the always-true spelling is not live code     2 the named helper is there
--   3 (Windows) it is FALSE for an absent target    4 (Windows) CONTROL the old predicate is TRUE
--
-- Usage: tillandsias-plan script run scripts/lua/test-cmdkey-predicate-discriminates.lua
-- Verdict: ok:cmdkey-predicate:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cmdkey-predicate")
-- Comments are stripped: the runbook DOCUMENTS the broken predicate beside its replacement.
local lines = {}
for l in (fs.read("skills/smoke-curl-install-and-test-e2e/SKILL.md"):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (l:gsub("^%s*#.*", ""))
end
local code = "\n" .. table.concat(lines, "\n") .. "\n"
local helper = code:match("\n(function Test%-TillandsiasCredPresent.-\n}\n)")
T:arm("1 the always-true spelling is not live code", not text.contains(code, "$out -match [regex]::Escape($cred)"), "found")
T:arm("2 the runbook has the named presence helper", helper ~= nil, "no Test-TillandsiasCredPresent function")

local function powershell(script)
    local r = T:run{ fixture.posix_shell(), "-s", "--", script, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        stdin = 'command -v powershell.exe >/dev/null 2>&1 && command -v cmdkey.exe >/dev/null 2>&1 || exit 9\npowershell.exe -NoProfile -Command "$1" </dev/null 2>/dev/null\n' }
    return r.code, text.trim(((r.stdout or ""):gsub("\r", "")))
end
if not text.contains((env.get("OS") or ""):lower(), "windows") or helper == nil then
    out.line("skip: 3 and 4 need a Windows host and the helper; nothing is asserted from prose")
    T:finish()
end
local ABSENT = "tillandsias-fixture-absent-target-1004vsh2"
local rc, v = powershell(helper .. 'if (Test-TillandsiasCredPresent "' .. ABSENT .. '") { "true" } else { "false" }')
T:arm("3 the shipped predicate is FALSE for an absent target", v == "false", "rc=" .. tostring(rc) .. " " .. v)
rc, v = powershell('$t = "' .. ABSENT .. '"; $out = (& cmdkey.exe "/list:$t" 2>$null | Out-String); if ($out -match [regex]::Escape($t)) { "true" } else { "false" }')
T:arm("4 CONTROL the old predicate is TRUE for the same target", v == "true", "rc=" .. tostring(rc) .. " " .. v)
T:finish()
