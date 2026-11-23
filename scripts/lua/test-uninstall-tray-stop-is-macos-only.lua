-- @trace order:1231-cbie, order:1401-p3k7, order:2109-umac
--
-- test-uninstall-tray-stop-is-macos-only.lua — 1231-cbie, the platform-guard
-- half. Ported from scripts/test-uninstall-tray-stop-is-macos-only.sh
-- (2109-umac) onto the scratch.* door and proc.spawn, with the same four arms.
--
-- THE TEETH ARE ARM 1: a DECOY process whose argv merely CONTAINS the tray's
-- literal must survive a Linux uninstall. Pre-fix it did not: the ladder sat at
-- column 0 under a macOS heading and sent SIGTERM then SIGKILL to anything
-- matching `-f` on every platform, in a SHIPPED release artifact. This runs the
-- uninstaller and looks at whether the decoy is alive; a source-shape check
-- would be the mention-versus-use shape.
--
-- The decoy is `tail -f <scratch>/<literal>.log`, so its argv carries the
-- literal with no shell wrapper, and the runner owns (and reaps) the process.
-- The literal is split so this file does not carry the string it tests for.
--
--   1 (teeth)  a decoy mentioning the literal survives a Linux uninstall
--   2 (positive control)  under a faked Darwin the guarded branch is REACHED
--     (`IS_MACOS=true` in bash -x), so arm 1 is a guard holding, not an
--     uninstaller dying early
--   3 the two-stage stop (TERM then KILL) still EXISTS for the Darwin path;
--     matcher-agnostic, and the TRAY_PROC seam must default to the tray
--   4 (1401-p3k7) a faked uname WITHOUT the sandbox seams is refused (rc 3)
--     before anything runs, under a PATH whose rm/pkill/pgrep/podman/launchctl/
--     sleep only RECORD
--
-- USAGE   tillandsias-plan script run scripts/lua/test-uninstall-tray-stop-is-macos-only.lua
-- GRAMMAR ok:uninstall-tray-stop-is-macos-only:4 (exit 0) | violation:...:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("uninstall-tray-stop-is-macos-only")

local U_REL = "scripts/uninstall.sh"
if not fs.exists(U_REL) then T:skip("no-uninstaller") end
local U = fixture.repo_root() .. "/" .. U_REL
local SRC = fs.read(U_REL)
local LIT = "tillandsias" .. "-tray"
local BASEPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

local w = T:scratch()
local function seamed_env(uname, bin)
    return {
        PATH = BASEPATH, HOME = w.abs,
        TILLANDSIAS_UNINSTALL_APPS_DIR = w.abs .. "/Applications",
        TILLANDSIAS_UNINSTALL_TRAY_PROC = "nonce-tray-1401",
        TILLANDSIAS_UNINSTALL_FAKE_UNAME = uname,
        TILLANDSIAS_UNINSTALL_INSTALL_DIR = w.abs .. "/" .. bin,
    }
end
local function sleep_ms(ms) proc.run{ argv = { "/bin/sleep", string.format("%.1f", ms / 1000) }, timeout_ms = ms + 5000 } end

-- ARM 1 — the teeth.
scratch.write(w.leaf .. "/" .. LIT .. ".log", "")
local decoy = proc.spawn{ argv = { "/usr/bin/tail", "-f", w.abs .. "/" .. LIT .. ".log" }, timeout_ms = 120000 }
sleep_ms(300)
local started = proc.select{ decoy, timeout_ms = 1 } == nil
if not started then
    T:arm("SETUP: the decoy started", false, "the decoy exited at once; nothing below measures anything")
else
    proc.run{ argv = { "bash", U, "--yes" }, env = seamed_env("Linux", "bin"), timeout_ms = 60000 }
    sleep_ms(1200)
    local chosen, why = proc.select{ decoy, timeout_ms = 1 }
    T:arm("ARM 1 (teeth): a process merely MENTIONING the literal survives a Linux uninstall",
        chosen == nil and why == "timed_out", "the decoy was KILLED by a Linux uninstall; the platform guard is not holding")
end
decoy:kill()

-- ARM 2 — POSITIVE CONTROL on the guard's own condition.
local r2 = proc.run{ argv = { "bash", "-x", U, "--yes" }, env = seamed_env("Darwin", "bin2"), timeout_ms = 60000 }
local seen = 0
for _, l in ipairs(text.lines((r2.stdout or "") .. (r2.stderr or ""))) do
    if text.is_match(l, "IS_MACOS.*=.*true") then seen = seen + 1 end
end
T:arm("ARM 2 (positive control): the Darwin arm is REACHED and sets IS_MACOS=true", seen > 0,
    "could not observe the Darwin arm being taken; arm 1 may be passing for the wrong reason")

-- ARM 3 — the guard is a PLATFORM test, not a deletion. Matcher-agnostic by
-- construction (1231-cbie second half); textual because a behavioural arm would
-- run the real matcher against a developer's live tray.
local TGT = '(tillandsias-tray|"[$]_tray")'
local two_stage = false
local has_term, has_kill = false, false
for _, l in ipairs(text.lines(SRC)) do
    if text.is_match(l, "pkill -TERM( -[a-zA-Z])? " .. TGT) then has_term = true end
    if text.is_match(l, "pkill -KILL( -[a-zA-Z])? " .. TGT) then has_kill = true end
end
local seam_ok = (not text.contains(SRC, '"$_tray"')) or text.contains(SRC, "TILLANDSIAS_UNINSTALL_TRAY_PROC:-tillandsias-tray}")
two_stage = has_term and has_kill and seam_ok
T:arm("ARM 3: the two-stage stop still EXISTS for the Darwin path (guarded, not deleted)", two_stage,
    "term=" .. tostring(has_term) .. " kill=" .. tostring(has_kill) .. " seam-default=" .. tostring(seam_ok))

-- ARM 4 — a faked uname without the seams is refused before anything runs.
scratch.mkdir(w.leaf .. "/stub4")
scratch.mkdir(w.leaf .. "/h4")
scratch.write(w.leaf .. "/calls4.log", "")
for _, c in ipairs({ "rm", "pkill", "pgrep", "podman", "launchctl", "sleep" }) do
    scratch.write(w.leaf .. "/stub4/" .. c, '#!/bin/sh\necho "' .. c .. ' $*" >> "' .. w.abs .. '/calls4.log"\nexit 0\n')
    scratch.chmod(w.leaf .. "/stub4/" .. c, tonumber("755", 8))
end
local r4 = proc.run{ argv = { "bash", U, "--yes" }, timeout_ms = 60000, env = {
    PATH = w.abs .. "/stub4:" .. BASEPATH, HOME = w.abs .. "/h4",
    TILLANDSIAS_UNINSTALL_FAKE_UNAME = "Darwin",
    TILLANDSIAS_UNINSTALL_INSTALL_DIR = w.abs .. "/bin4",
} }
local rc4 = (r4.status == "exited") and r4.code or -1
local o4 = (r4.stdout or "") .. (r4.stderr or "")
local log4 = scratch.read(w.leaf .. "/calls4.log")
T:arm("ARM 4: a faked uname without the APPS_DIR/TRAY_PROC seams is refused (rc=3) before any rm or pkill",
    rc4 == 3 and text.contains(o4, "refused:uninstall:fake-uname-without-sandbox-seams") and log4 == "",
    "rc=" .. rc4 .. "; it would have run: " .. log4:gsub("\n", ";"))

T:finish()
