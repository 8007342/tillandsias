-- @trace spec:host-state-lifecycle, order:1437-8c6p, order:2108-hmfx
--
-- test-install-macos-setup-is-quiet.lua — install-macos.sh runs the SOFT reset,
-- keeps the tray's reset output in the setup log, and prints no power-user
-- text. Ported from scripts/test-install-macos-setup-is-quiet.sh (2108-hmfx)
-- onto the scratch.* door, with the same arms. The Linux twin is
-- scripts/lua/test-install-linux-setup-is-quiet.lua.
--
-- Operator ruling 2026-10-08, verbatim: "we do not need to print any power user
-- messages during install, at all. Install should be for END USER (NOT POWER
-- USER) and be a pretty installer, rather than an informational/debugging
-- installer." MEASURED on the v56.10.9.1 smoke (macbookair, 2026-10-09), the
-- installer's terminal carried "TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 skips the
-- destruction" from install-macos.sh and "Skip the reset with
-- TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. This is the ONLY opt-out." from the tray.
--
-- HOW IT TESTS. The real installer quits a running tray and writes
-- /Applications, so it never runs here. This RUNS the installer's own reset
-- block (between `# BEGIN-SETUP-RESET` and `# END-SETUP-RESET`, cut from the
-- file, not copied) in bash against a scratch HOME and a stub tray that prints
-- the real banner's shape. Arms:
--   1  the reset block is marked in the installer
--   1b the block runs to completion against a passing tray
--   2  its terminal output has no TILLANDSIAS_ token and no flag name
--   3  the setup log holds the tray's banner
--   4  a failing reset exits non-zero, names the log, and stays quiet
--   5  the installer's code has exactly one reset call, --reset-state with
--      stdin from /dev/null, and no HARD path
--   6  no say/die text from the reset block to the end names a flag or variable
--   7  NEGATIVE CONTROL: the quietness detector flags the measured smoke line
--
-- USAGE   tillandsias-plan script run scripts/lua/test-install-macos-setup-is-quiet.lua
-- GRAMMAR ok:install-macos-setup-is-quiet:8 (exit 0) | violation:install-macos-setup-is-quiet:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("install-macos-setup-is-quiet")

local SRC_REL = "scripts/install-macos.sh"
if not fs.exists(SRC_REL) then
    verdict.could_not_run("install-macos-setup-is-quiet", "no " .. SRC_REL)
end
local SRC = fs.read(SRC_REL)
local lines = text.lines(SRC)

-- Power-user text: a TILLANDSIAS_ variable, or a flag (`--` then a letter, not
-- inside a word or after another dash). Returns the first offending line.
local function noisy(s)
    for _, l in ipairs(text.lines(s)) do
        if l:find("TILLANDSIAS_", 1, true) or (" " .. l):find("[^%w%-]%-%-%l") then return l end
    end
    return nil
end
local function flat(s) return (string.gsub(string.sub(s or "", 1, 300), "\n", "|")) end

local block, inside = {}, false
for _, l in ipairs(lines) do
    if l:find("^# BEGIN%-SETUP%-RESET") then inside = true
    elseif l:find("^# END%-SETUP%-RESET") then inside = false
    elseif inside then block[#block + 1] = l end
end
T:arm("1 the reset block is marked in the installer", #block > 0, "no # BEGIN-SETUP-RESET block")
if #block == 0 then
    -- Run what the installer has instead, so arms 2-4 measure the real text.
    local f = false
    for _, l in ipairs(lines) do
        if l:find("ORDER 1286-4437", 1, true) then f = true end
        if l:find("^# ── login item") then f = false end
        if f then block[#block + 1] = l end
    end
end

local w = T:scratch()
-- The stub: the shape of the real reset banner (core announce_reset_plan plus
-- the macOS SOFT body), exiting with $STUB_EXIT.
scratch.mkdir(w.leaf .. "/app/Contents/MacOS")
local STUB = w.leaf .. "/app/Contents/MacOS/tillandsias-tray"
scratch.write(STUB, table.concat({
    "#!/usr/bin/env bash",
    'echo "[tillandsias] reset: SOFT" >&2',
    'echo "[tillandsias] --reset-state: resetting local state before reprovisioning." >&2',
    'echo "[tillandsias]   WILL BE PRESERVED:" >&2',
    'echo "[tillandsias]   Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. This is the ONLY opt-out." >&2',
    'echo "Already provisioned: /scratch/rootfs.img"',
    'exit "${STUB_EXIT:-0}"',
}, "\n") .. "\n")
scratch.chmod(STUB, tonumber("755", 8))
scratch.write(w.leaf .. "/harness.sh", "set -euo pipefail\n"
    .. 'say() { printf "  %s\\n" "$*"; }\n'
    .. 'die() { printf "  ERROR: %s\\n" "$*" >&2; exit 1; }\n'
    .. table.concat(block, "\n") .. "\n")

local function run_block(code) -- -> rc, terminal
    scratch.mkdir(w.leaf .. "/home." .. code)
    local r = proc.run{ argv = { "bash", w.abs .. "/harness.sh" }, timeout_ms = 60000, env = {
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin",
        HOME = w.abs .. "/home." .. code,
        DEST = w.abs .. "/app",
        STUB_EXIT = tostring(code),
    } }
    return (r.status == "exited") and r.code or -1, (r.stdout or "") .. (r.stderr or "")
end

local rc, term = run_block(0)
T:arm("1b the block runs to completion against a passing tray", rc == 0, "rc=" .. rc .. " | " .. flat(term))
local hit = noisy(term)
T:arm("2 no TILLANDSIAS_ token and no flag name on the terminal", hit == nil, hit)
local LOG = w.leaf .. "/home.0/Library/Logs/Tillandsias/setup.log"
local log = scratch.exists(LOG) and scratch.read(LOG) or ""
T:arm("3 the setup log holds the tray's banner",
    text.contains(log, "WILL BE PRESERVED") and text.contains(log, "reset: SOFT"), "log: " .. flat(log))

local rc7, term7 = run_block(7)
T:arm("4 a failing reset exits non-zero, names the log, and stays quiet",
    rc7 ~= 0 and text.contains(term7, "Library/Logs/Tillandsias/setup.log") and noisy(term7) == nil,
    "rc=" .. rc7 .. " | " .. flat(term7))

-- 5: one SOFT call, stdin from /dev/null, no HARD path in the installer's code.
local function strip_comment(l) return (l:gsub("^#.*", ""):gsub("(%s)#.*", "%1")) end
local calls, hard = 0, {}
local HARD = { "--reset-guest", "--approve-hard-reset", "TILLANDSIAS_HARD_RESET_APPROVED", "TILLANDSIAS_INSTALL_RESET" }
local seen = {}
for _, l in ipairs(lines) do
    local c = strip_comment(l)
    if c:find("--reset-state </dev/null", 1, true) then calls = calls + 1 end
    for _, tok in ipairs(HARD) do
        if not seen[tok] and c:find(tok, 1, true) then seen[tok] = true; hard[#hard + 1] = tok end
    end
end
T:arm("5 exactly one --reset-state call, stdin from /dev/null, no HARD path",
    calls == 1 and #hard == 0, "calls=" .. calls .. " hard=[" .. table.concat(hard, " ") .. "]")

-- 6: the text of every say/die from the reset block to the end, variables
-- dropped (a reader sees the value, not its name). The --login-item line echoes
-- a flag the user passed themselves, so it is not power-user text.
local said, f = {}, false
for _, l in ipairs(lines) do
    if l:find("^# BEGIN%-SETUP%-RESET") or l:find("ORDER 1286-4437", 1, true) then f = true end
    if f then
        local c = strip_comment(l)
        local sp = " " .. c
        if (sp:find("%ssay%s") or sp:find("%sdie%s")) and not c:find("--login-item", 1, true) then
            said[#said + 1] = (c:gsub("%${[^}]*}", ""):gsub("%$[%a_][%w_]*", ""))
        end
    end
end
local hit6 = noisy(table.concat(said, "\n"))
T:arm("6 no say/die text after the swap names a flag or variable (" .. #said .. " lines)",
    #said > 0 and hit6 == nil, hit6 or "no say/die lines found: the population is empty")

-- 7: NEGATIVE CONTROL — the detector catches the line the smoke measured.
T:arm("7 NEGATIVE CONTROL: the measured smoke line is flagged",
    noisy("  resetting local state (--reset-state); TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 skips the destruction") ~= nil,
    "the detector cannot see the measured smoke line")

T:finish()
