-- @trace order:1244-9dx3, order:1426-cb6g, order:2105-mlua, spec:macos-tray-build-and-release
--
-- test-install-macos-tray-stop.lua — install-macos.sh stops a running tray by
-- the routes that DRAIN its VM, and never SIGKILLs it before a drain can finish.
-- Ported from scripts/test-install-macos-tray-stop.sh (2105-mlua), same arms.
--
-- MEASURED on the v56.9.27.1 smoke (2026-09-27): `tell application
-- "tillandsias-tray" to quit` (the EXECUTABLE name; AppleScript resolves bundle
-- names/ids) left a running tray alive for 30 s, so every reinstall fell through
-- to `pkill -TERM`, which the tray did not handle, so the VM stop path never
-- ran and the per-launch vm-swap.img survived. The tray now drains on the quit
-- Apple event and on SIGTERM; this fixture pins the installer side:
--   1. the bundle declares a CFBundleIdentifier, and the graceful stage
--      addresses the app by that BUNDLE ID (drift guard);
--   2. the executable-name form is gone;
--   3. no SIGKILL can happen before the tray's VM_STOP_DRAIN bound has elapsed.
-- Static by construction: the stage is inline in an installer that downloads
-- and swaps /Applications, and this fixture must never touch /Applications.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-install-macos-tray-stop.lua
-- GRAMMAR (last line on stdout)
--   ok:install-macos-tray-stop:<n>           exit 0
--   refused:install-macos-tray-stop          exit 1  (failed arms on stdout above)

local INST = "scripts/install-macos.sh"
local PLIST = "crates/tillandsias-macos-tray/assets/Info.plist.template"
local HOST = "crates/tillandsias-macos-tray/src/action_host.rs"

local pass, fail = 0, 0
local function ok(msg) pass = pass + 1; out.line("ok   " .. msg) end
local function bad(msg) fail = fail + 1; out.line("FAIL " .. msg) end

local function read(path)
    if not fs.exists(path) then
        verdict.could_not_run("install-macos-tray-stop", "missing " .. path)
    end
    return fs.read(path)
end

local inst, plist, host = read(INST), read(PLIST), read(HOST)
local inst_lines = text.lines(inst)

-- 1. The bundle id: the <string> on the line after <key>CFBundleIdentifier</key>.
local bid = ""
local plines = text.lines(plist)
for i, l in ipairs(plines) do
    if text.contains(l, "<key>CFBundleIdentifier</key>") and plines[i + 1] then
        bid = plines[i + 1]:match("<string>(.-)</string>") or ""
        break
    end
end
if bid ~= "" then
    ok("the bundle declares CFBundleIdentifier=" .. bid)
else
    bad("no CFBundleIdentifier in " .. PLIST)
end

if bid ~= "" and text.contains(inst, 'tell application id "' .. bid .. '" to quit') then
    ok("the graceful stage addresses the tray by its bundle id")
else
    bad('the graceful stage does not address the app by bundle id "' .. bid .. '"')
end

-- 2. The executable-name form never reaches a running tray.
if text.contains(inst, 'tell application "tillandsias-tray"') then
    bad("the executable-name form is still present (it never reaches a running tray)")
else
    ok("the executable-name form is gone")
end

-- 3. Every _tray_wait before the SIGKILL exceeds the drain bound.
local drain
for _, l in ipairs(text.lines(host)) do
    local n = l:match("^const VM_STOP_DRAIN: Duration = Duration::from_secs%((%d+)%);")
    if n then drain = tonumber(n); break end
end
local waits, kill_line = {}, nil
for i, l in ipairs(inst_lines) do
    for w in l:gmatch("_tray_wait (%d+)") do waits[#waits + 1] = tonumber(w) end
    if not kill_line and text.contains(l, "pkill -KILL -x tillandsias-tray") then kill_line = i end
end
local waits_s = table.concat(waits, " ")
if not drain or #waits == 0 or not kill_line then
    bad("could not read the drain bound (" .. tostring(drain or "") .. "), the waits (" .. waits_s
        .. ") or the SIGKILL line (" .. tostring(kill_line or "") .. ")")
else
    local short = false
    for _, w in ipairs(waits) do if w <= drain then short = true end end
    if not short then
        ok("every wait (" .. waits_s .. " s) exceeds the tray's " .. drain .. "s drain bound before SIGKILL")
    else
        bad("a wait (" .. waits_s .. " s) does not exceed the " .. drain .. "s drain: SIGKILL could cut a drain short")
    end
end

if fail > 0 then
    verdict.refused("install-macos-tray-stop", fail .. " arm(s) failed")
end
verdict.ok("install-macos-tray-stop", tostring(pass))
