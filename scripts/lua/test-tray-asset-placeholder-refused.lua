-- @env PATH SystemRoot SYSTEMROOT windir
-- @trace order:1059-ry6t, order:2361-y7pf
--
-- test-tray-asset-placeholder-refused.lua — a windows-tray build that would embed a ZERO-BYTE guest binary
-- warns at build time (build.rs) and is refused at package time (build-windows-tray.ps1). build.rs writes an
-- empty placeholder so `cargo check` compiles; without the refusal the tray's guest injection was a silent
-- no-op. Ported from the .sh of the same name; arms 1-2 now EXECUTE the script's own condition, where the
-- .sh executed a copy of it. Scans strip comments: the prose beside a guard must not stand in for it.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tray-asset-placeholder-refused.lua
-- Verdict: ok:tray-asset-placeholder:<n> arms | violation:tray-asset-placeholder:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("tray-asset-placeholder")
local PS1, RS, SKILL = "scripts/build-windows-tray.ps1", "crates/tillandsias-windows-tray/build.rs", "skills/build-windows-tray/SKILL.md"
for _, f in ipairs{ PS1, RS, SKILL } do if not fs.exists(f) then T:refuse("subject-missing", f) end end

local function strip(path, marker)
    local t = {}
    for l in (fs.read(path):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        t[#t + 1] = l:find("^%s*" .. marker) and "" or l
    end
    return table.concat(t, "\n")
end
local ps, rs = strip(PS1, "#"), strip(RS, "//")

-- Where each property is judged, so the MUTATION arms judge the same way.
local function condition(code) return code:match("\n%s*if (%b()) { %$missing %+= %$asset }") end
local function refuses_before_built(code)
    local guard = code:find("if ($missing.Count -gt 0) {\n    throw @\"\nguest asset is a placeholder", 1, true)
    local built = code:find("Built: $exe", 1, true)
    return guard and built and guard < built or false
end
local function warns_on_condition(code)
    local zero = code:find("m.len() == 0", 1, true)
    local ask = zero and code:find("if is_placeholder {", zero, true)
    return ask and code:find('^%s*println!%(%s*"cargo:warning=tillandsias%-windows%-tray: {} is 0 bytes', ask + 19) ~= nil or false
end

local cond = condition(ps)
T:arm("3 packaging has an asset condition", cond ~= nil, "none")
T:arm("3 and it tests the LENGTH", text.contains(cond or "", "(Get-Item $asset).Length -eq 0"), cond)

-- The probe is checked before its answer is trusted: under WSL interop powershell.exe starts, and the
-- fixture's paths mean nothing to it. An absent answer is a named skip, not a verdict.
local W = T:scratch()
fs.write(W.rel .. "/placeholder", "")
fs.write(W.rel .. "/real", "ELF-ish real bytes")
local function powershell(body)
    fs.write(W.rel .. "/run.ps1", body .. "\n")
    local r = T:run{ "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", W.abs .. "/run.ps1", timeout_ms = 60000 }
    return text.trim(r.stdout or "")
end
local function verdict_on(name)
    return powershell("$asset = '" .. W.abs .. "/" .. name .. "'; if " .. (cond or "($true)") .. " { 'missing' } else { 'ok' }")
end
if not W.abs:find("^%a:") then
    out.line("skip: 1-2 the PowerShell condition is executed on native Windows only")
elseif powershell("'probe-ok'") ~= "probe-ok" then
    out.line("skip: 1-2 powershell did not answer")
else
    local v = verdict_on("placeholder")
    T:arm("1 a zero-byte asset is detected", v == "missing", v)
    v = verdict_on("absent")
    T:arm("1 an absent asset is detected", v == "missing", v)
    v = verdict_on("real")
    T:arm("2 CONTROL a real asset is not flagged", v == "ok", v)
end

T:arm("3 packaging throws on it before it says Built", refuses_before_built(ps), "no throw, or after Built")
T:arm("4 build.rs warns on the zero-byte CONDITION, not only on creation", warns_on_condition(rs), "not found")
local skill = fs.read(SKILL):lower()
T:arm("5 the skill names the staging step", skill:find("musl", 1, true) ~= nil or skill:find("include_bytes", 1, true) ~= nil
    or skill:find("placeholder", 1, true) ~= nil, "none of musl, include_bytes, placeholder")

-- MUTATION. Each edit must land.
local function swap(s, from, to)
    local a, b = s:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return s:sub(1, a - 1) .. to .. s:sub(b + 1)
end
T:arm("6 MUTATION a condition that only tests existence fails arm 3", not text.contains(
    condition(swap(ps, " -or ((Get-Item $asset).Length -eq 0)", "")) or "", "Length -eq 0"), "still found")
T:arm("6 MUTATION a packaging script that does not throw fails arm 3",
    not refuses_before_built(swap(ps, "    throw @\"\nguest asset", "    Write-Warning @\"\nguest asset")), "still refuses")
T:arm("6 MUTATION a throw after Built fails arm 3",
    not refuses_before_built("Built: $exe\n" .. ps), "still refuses")
T:arm("6 MUTATION a build.rs that asks another question fails arm 4",
    not warns_on_condition(swap(rs, "m.len() == 0", "m.len() == 1")), "still warns")

T:finish()
