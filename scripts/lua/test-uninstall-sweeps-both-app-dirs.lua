-- @trace order:1365-tjav, order:1401-p3k7, order:2109-umac
--
-- test-uninstall-sweeps-both-app-dirs.lua — fixture for the macOS uninstall
-- sweep (plan/issues/macos-uninstall-misses-the-default-install-dir-2026-08-30.md).
-- Ported from scripts/test-uninstall-sweeps-both-app-dirs.sh (2109-umac) onto
-- the scratch.* door, with the same assertions.
--
-- THE DEFECT THIS PINS: install-macos.sh prefers /Applications and falls back
-- to $HOME/Applications only when /Applications is not writable. uninstall.sh
-- used to remove ONLY the $HOME path, so on the DEFAULT target uninstall left
-- the app installed while removing the LaunchAgent beside it.
--
-- PLATFORM-INDEPENDENT, deliberately: the uninstaller's macOS cleanup block is
-- cut from the file (not copied) and run against a scratch HOME and a seamed
-- /Applications, so every lane can catch a regression. The block's process
-- commands (pgrep, pkill, killall) resolve to shims that RECORD and never
-- signal, and PROC-SCOPE proves they were intercepted (1365-tjav). Its negative
-- control runs the block WITHOUT the shims; that is safe only because the tray
-- seam names a nonce, so the real pkill matches nothing.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-uninstall-sweeps-both-app-dirs.lua
-- GRAMMAR ok:uninstall-sweeps-both-app-dirs:<n> (exit 0) | violation:uninstall-sweeps-both-app-dirs:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("uninstall-sweeps-both-app-dirs")

local U_REL = "scripts/uninstall.sh"
if not fs.exists(U_REL) then T:refuse("no-uninstaller", "no " .. U_REL) end

-- The block: from the '── macOS desktop cleanup' banner through the first
-- `rm -f "$HOME/Library/LaunchAgents...` line (the shell used the same sed range).
local block, inside = {}, false
for _, l in ipairs(text.lines(fs.read(U_REL))) do
    if not inside and l:find("── macOS desktop cleanup", 1, true) then inside = true end
    if inside then
        block[#block + 1] = l
        if l:find('^rm %-f "%$HOME/Library/LaunchAgents') then break end
    end
end
if #block == 0 then
    T:refuse("macos-cleanup-block-not-found",
        "the fixture locates the block by its '── macOS desktop cleanup' banner; if it was renamed, update this fixture, do not delete the assertion")
end
local B = table.concat(block, "\n") .. "\n"

-- Textual intent, because a sweep that lost one dir would still pass a test
-- that only stubbed the other, which is exactly how the original defect hid.
T:arm("the block names /Applications", text.contains(B, "/Applications"), "no /Applications")
T:arm("the block names $HOME/Applications", text.contains(B, "HOME/Applications"), "no HOME/Applications")
T:arm("the block removes the .bak sibling", text.contains(B, "Tillandsias.app.bak"), "no Tillandsias.app.bak")
-- The tray must be STOPPED before its bundle is deleted; asserted textually,
-- never behaviourally against the real name. Matcher-agnostic (1231-cbie).
T:arm("the block stops the running tray",
    text.is_match(B, 'pkill -TERM( -[a-zA-Z])? (tillandsias-tray|"[$]_tray")'), "no pkill -TERM of the tray")
T:arm("the tray seam defaults to the tray", text.contains(B, "TILLANDSIAS_UNINSTALL_TRAY_PROC:-tillandsias-tray}"),
    "no TRAY_PROC default")
T:arm("the apps seam defaults to /Applications", text.contains(B, "TILLANDSIAS_UNINSTALL_APPS_DIR:-/Applications}"),
    "no APPS_DIR default")

local w = T:scratch()
local SYS, HOME = w.leaf .. "/Applications", w.leaf .. "/home"
scratch.mkdir(HOME .. "/Library/LaunchAgents")
for _, d in ipairs({ SYS, HOME .. "/Applications" }) do
    for _, app in ipairs({ "Tillandsias.app", "Tillandsias.app.bak" }) do
        scratch.mkdir(d .. "/" .. app .. "/Contents/MacOS")
        scratch.write(d .. "/" .. app .. "/Contents/MacOS/tillandsias-tray", "stub\n")
    end
end
scratch.write(HOME .. "/Library/LaunchAgents/com.tillandsias.tray.plist", "stub\n")
scratch.write(w.leaf .. "/block.sh", B)

-- Shims that record and never signal.
scratch.mkdir(w.leaf .. "/procshim")
for _, c in ipairs({ "pgrep", "pkill", "killall" }) do
    scratch.write(w.leaf .. "/procshim/" .. c,
        '#!/bin/sh\necho "' .. c .. ' $*" >> "' .. w.abs .. '/proc-calls"\nexit 0\n')
    scratch.chmod(w.leaf .. "/procshim/" .. c, tonumber("755", 8))
end

local BASEPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
local function run_block(shimmed)
    local r = proc.run{ argv = { "bash", w.abs .. "/block.sh" }, timeout_ms = 30000, env = {
        IS_MACOS = "true",
        HOME = w.abs .. "/home",
        PATH = shimmed and (w.abs .. "/procshim:" .. BASEPATH) or BASEPATH,
        TILLANDSIAS_UNINSTALL_APPS_DIR = w.abs .. "/Applications",
        TILLANDSIAS_UNINSTALL_TRAY_PROC = "nonce-tray-1401",
    } }
    return (r.status == "exited") and r.code or -1, (r.stdout or "") .. (r.stderr or "")
end
local function calls()
    local p = w.leaf .. "/proc-calls"
    return scratch.exists(p) and scratch.read(p) or ""
end
-- PROC-SCOPE: the stop reached the shims (TERM then KILL) and named only the nonce.
local function proc_scoped(s)
    local term, kill, stray = false, false, false
    for _, l in ipairs(text.lines(s)) do
        if l:find("^pkill %-TERM") then term = true end
        if l:find("^pkill %-KILL") then kill = true end
        if l ~= "" and not l:find("nonce-tray-1401", 1, true) then stray = true end
    end
    return term and kill and not stray
end

scratch.write(w.leaf .. "/proc-calls", "")
local rc, o = run_block(true)
T:arm("the block exits 0", rc == 0, "rc=" .. rc .. " | " .. o)
T:arm("PROC-SCOPE: the tray stop reached only the shims and only the nonce", proc_scoped(calls()), calls())
-- NEGATIVE CONTROL: without the shims nothing is recorded, so the same arm reds.
scratch.write(w.leaf .. "/proc-calls", "")
run_block(false)
T:arm("NEGATIVE CONTROL: proc-scope does not pass without its shims", not proc_scoped(calls()), calls())

T:arm("the system app is swept", not scratch.exists(SYS .. "/Tillandsias.app"), "survived")
T:arm("the system .bak is swept", not scratch.exists(SYS .. "/Tillandsias.app.bak"), "survived")
T:arm("the home app is swept", not scratch.exists(HOME .. "/Applications/Tillandsias.app"), "survived")
T:arm("the home .bak is swept", not scratch.exists(HOME .. "/Applications/Tillandsias.app.bak"), "survived")
T:arm("the LaunchAgent is removed", not scratch.exists(HOME .. "/Library/LaunchAgents/com.tillandsias.tray.plist"), "survived")

-- An absent fallback dir must not make the sweep fail.
scratch.rm(HOME .. "/Applications")
local rc2, o2 = run_block(true)
T:arm("an absent $HOME/Applications does not fail the sweep", rc2 == 0, "rc=" .. rc2 .. " | " .. o2)

T:finish()
