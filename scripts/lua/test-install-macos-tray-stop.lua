-- @trace order:2080-zcur
--
-- test-install-macos-tray-stop.lua — scripts/install-macos.sh stops a running
-- tray gracefully before it swaps the bundle: the graceful stage addresses
-- the app by its bundle id (the executable-name form never reaches a running
-- tray), and every wait before SIGKILL outlasts the tray's VM drain bound.
-- Ported from scripts/test-install-macos-tray-stop.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-install-macos-tray-stop.lua
-- Verdict: ok:install-macos-tray-stop:<n> arms | violation:install-macos-tray-stop:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("install-macos-tray-stop")
local INST = fs.read("scripts/install-macos.sh") or ""
local PLIST = fs.read("crates/tillandsias-macos-tray/assets/Info.plist.template") or ""
local HOST = fs.read("crates/tillandsias-macos-tray/src/action_host.rs") or ""

local bid = PLIST:match("<key>CFBundleIdentifier</key>%s*<string>([^<]*)</string>")
T:arm("the bundle declares CFBundleIdentifier", bid ~= nil and bid ~= "", "no CFBundleIdentifier in Info.plist.template")
T:arm("the graceful stage addresses the tray by its bundle id",
    bid and text.contains(INST, 'tell application id "' .. bid .. '" to quit'), "bundle id " .. tostring(bid))
T:arm("the executable-name form is gone", not text.contains(INST, 'tell application "tillandsias-tray"'),
    "still present (it never reaches a running tray)")

local drain
for _, l in ipairs(text.lines(HOST)) do
    drain = drain or l:match("^const VM_STOP_DRAIN: Duration = Duration::from_secs%((%d+)%);")
end
local waits = {}
for w in INST:gmatch("_tray_wait (%d+)") do waits[#waits + 1] = tonumber(w) end
local killed = text.contains(INST, "pkill -KILL -x tillandsias-tray")
local short = false
for _, w in ipairs(waits) do if not drain or w <= tonumber(drain) then short = true end end
T:arm("every wait exceeds the tray's drain bound before SIGKILL",
    drain and #waits > 0 and killed and not short,
    "drain=" .. tostring(drain) .. " waits=" .. table.concat(waits, " ") .. " kill=" .. tostring(killed))
T:finish()
