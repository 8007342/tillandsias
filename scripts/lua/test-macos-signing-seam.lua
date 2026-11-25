-- @trace spec:macos-tray-build-and-release, order:935-6fzk, order:2111-inst
--
-- test-macos-signing-seam.lua — the macOS signing seam behaves in BOTH modes.
-- Ported from scripts/test-macos-signing-seam.sh (2111-inst) onto the scratch.*
-- door, with the same checks. The shell copy was bound to nothing; this port is
-- bound by gate step 403-2111-inst-signing-seam.
--
-- build-macos-tray.sh signs ad-hoc by default and with a Developer ID when
-- TILLANDSIAS_MACOS_SIGN_IDENTITY is set. The Developer-ID half needs a
-- credential this host does not have, so this pins the parts that do not.
-- The one silent failure is `com.apple.security.get-task-allow`: required for
-- local debugging, and NOTARIZATION REJECTS ANY BUILD CARRYING IT.
--
--   1 the default identity is ad-hoc
--   2 --options runtime is in BOTH signing arms
--   3 --timestamp is scoped to the Developer ID arm
--   4 the BUILD strips get-task-allow (textual, because 4b-4c are
--     self-certifying), then 4b-4c run that derivation on a scratch copy of the
--     entitlements: get-task-allow dropped, virtualization kept. PlistBuddy is
--     macOS-only, so 4b-4c are a NAMED skip elsewhere.
--   5 stapling precedes packaging
--   6 notarization is credential-gated and says when it is skipped
--   7 the DMG container is signed too (935-6fzk)
--   8 DMG signing and notarization are gated and say so
--   9 the DMG hash is taken AFTER signing
-- NOT COVERED: a real Developer ID signature, notarytool and stapler.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-macos-signing-seam.lua
-- GRAMMAR ok:macos-signing-seam:<n> (exit 0) | violation:macos-signing-seam:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("macos-signing-seam")

local BUILD_REL = "scripts/build-macos-tray.sh"
local ENT_REL = "crates/tillandsias-macos-tray/assets/Tillandsias.entitlements"
local DMG_REL = "scripts/build-macos-dmg.sh"
if not fs.exists(BUILD_REL) then T:refuse("no-build-script", BUILD_REL) end
if not fs.exists(ENT_REL) then T:refuse("no-entitlements", ENT_REL) end
local BUILD = fs.read(BUILD_REL)
local DMG = fs.exists(DMG_REL) and fs.read(DMG_REL) or ""
local has = text.contains
local function first_line(src, needle, anchored)
    for i, l in ipairs(text.lines(src)) do
        if anchored and l:sub(1, #needle) == needle or (not anchored and l:find(needle, 1, true)) then return i end
    end
    return nil
end

T:arm("1 an unset identity defaults to ad-hoc", has(BUILD, 'SIGN_IDENTITY="${TILLANDSIAS_MACOS_SIGN_IDENTITY:--}"'),
    "the default signing identity is no longer ad-hoc")

local rt = 0
for _, l in ipairs(text.lines(BUILD)) do if l:find("--options runtime", 1, true) then rt = rt + 1 end end
T:arm("2 --options runtime is present in both signing arms", rt >= 2, "lines with it: " .. rt)

-- 3: --timestamp exists, and not within the two lines after an ad-hoc `sign - `.
local lines = text.lines(BUILD)
local adhoc_ts = false
for i, l in ipairs(lines) do
    if l:find("sign - ", 1, true) then
        for j = i, math.min(i + 2, #lines) do if lines[j]:find("--timestamp", 1, true) then adhoc_ts = true end end
    end
end
T:arm("3 --timestamp is scoped to the Developer ID arm", has(BUILD, "--timestamp") and not adhoc_ts,
    "present=" .. tostring(has(BUILD, "--timestamp")) .. " in-ad-hoc-arm=" .. tostring(adhoc_ts))

T:arm("4 the build script itself strips get-task-allow for release signing",
    has(BUILD, "Delete :com.apple.security.get-task-allow"), "notarization would reject every release")
local PB = "/usr/libexec/PlistBuddy"
local probe = proc.run{ argv = { PB, "-h" }, timeout_ms = 10000 }
if probe.status ~= "exited" then
    out.line("skip:macos-signing-seam:4b-4c:no-PlistBuddy (macOS-only); the derivation was NOT exercised")
else
    local w = T:scratch()
    scratch.write(w.leaf .. "/ent.plist", fs.read(ENT_REL))
    local ent = w.abs .. "/ent.plist"
    proc.run{ argv = { PB, "-c", "Delete :com.apple.security.get-task-allow", ent }, timeout_ms = 10000 }
    local gta = proc.run{ argv = { PB, "-c", "Print :com.apple.security.get-task-allow", ent }, timeout_ms = 10000 }
    T:arm("4b release entitlements drop get-task-allow", gta.code ~= 0, "get-task-allow SURVIVED the derivation")
    local virt = proc.run{ argv = { PB, "-c", "Print :com.apple.security.virtualization", ent }, timeout_ms = 10000 }
    T:arm("4c release entitlements KEEP com.apple.security.virtualization", virt.code == 0,
        "virtualization entitlement was lost: the VM would refuse to start")
end

local staple, tar = first_line(BUILD, "stapler staple"), first_line(BUILD, "tar -czf")
T:arm("5 stapling precedes packaging", staple and tar and staple < tar,
    "staple_line=" .. tostring(staple) .. " tar_line=" .. tostring(tar))
T:arm("6 notarization is credential-gated and announces when it is skipped",
    has(BUILD, "TILLANDSIAS_NOTARY_KEY") and has(BUILD, "notarize: SKIPPED"), "not gated, or silent when skipped")
T:arm("7 the DMG itself is signed, not just the app inside it",
    has(DMG, 'codesign --force --sign "$DMG_SIGN_IDENTITY"'), "build-macos-dmg.sh must sign the DMG container")
T:arm("8 DMG signing and notarization are gated and announce when skipped",
    has(DMG, "codesign dmg: SKIPPED") and has(DMG, "notarize dmg: SKIPPED"), "not gated, or silent")
local sign, sha = first_line(DMG, 'codesign --force --sign "$DMG_SIGN_IDENTITY"'), first_line(DMG, "DMG_SHA=", true)
T:arm("9 the DMG hash is computed after signing", sign and sha and sign < sha,
    "sign_line=" .. tostring(sign) .. " sha_line=" .. tostring(sha))

T:finish()
