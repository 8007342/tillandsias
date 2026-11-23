-- @trace order:1281-pgit, order:2108-hmfx
--
-- test-install-macos-swap-is-interruptible.lua — ported from
-- scripts/test-install-macos-swap-is-interruptible.sh (2108-hmfx) onto the
-- scratch.* door (rename is its own verb there), with the same six checks.
--
-- THE PROPERTY: an install interrupted at ANY point between download and launch
-- leaves EITHER the old app OR the new app runnable at the destination, never
-- neither.
--
-- WHY IT EXISTS. install-macos.sh used to `rm -rf` the old backup, `mv` the LIVE
-- app aside, and only then extract. That left the destination EMPTY for the
-- whole extraction. MEASURED on macneo 2026-09-19: the installer was killed by
-- SIGPIPE mid-swap and /Applications held NEITHER Tillandsias.app NOR
-- Tillandsias.app.bak.
--
-- HOW IT TESTS. The installer downloads from GitHub and launches a tray, neither
-- of which belongs in a gate. So this reproduces the SWAP CONTRACT against a
-- scratch prefix: a staging extract, the two adjacent renames, the cleanup that
-- restores on a trappable death, and the deferred removal of the previous
-- backup. Each arm stops the sequence at a step boundary and asserts the
-- invariant:
--   1 stopped AFTER the staging extract, BEFORE any rename  -> old app intact
--   2 stopped BETWEEN the two renames (the old window)      -> restored by cleanup
--   3 stopped AFTER the swap, BEFORE the old .bak is removed -> new app in place
--   4 a clean run -> new app, backup kept, and no staging dir left behind
--   5 NEGATIVE CONTROL: the OLD ordering, same stop as arm 2 -> NEITHER present,
--     proving the arms detect the defect rather than passing for free.
-- The installer itself is read only to confirm it still exists; the contract
-- mirrored here is the one install-macos.sh's swap block documents.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-install-macos-swap-is-interruptible.lua
-- GRAMMAR ok:install-macos-swap-is-interruptible:6 (exit 0) | violation:...:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("install-macos-swap-is-interruptible")

if not fs.exists("scripts/install-macos.sh") then
    verdict.could_not_run("install-macos-swap-is-interruptible", "no scripts/install-macos.sh")
end

local APP = "Tillandsias.app"
local MARK = "/Contents/MacOS/marker"

-- A scratch prefix standing in for /Applications, with an "old app" in it.
local function new_prefix(tag)
    local d = T:scratch(tag)
    scratch.mkdir(d.leaf .. "/" .. APP .. "/Contents/MacOS")
    scratch.write(d.leaf .. "/" .. APP .. MARK, "OLD\n")
    return d.leaf
end
local function marker_of(p)
    local m = p .. "/" .. APP .. MARK
    return scratch.exists(m) and text.trim(scratch.read(m)) or "ABSENT"
end
-- "Extracting the release asset": the new app appears inside the stage dir.
local function extract_into(stage)
    scratch.mkdir(stage .. "/" .. APP .. "/Contents/MacOS")
    scratch.write(stage .. "/" .. APP .. MARK, "NEW\n")
end

-- The FIXED sequence, with a stop point. Mirrors install-macos.sh's swap.
local function run_fixed(P, stop)
    local DEST, BACKUP = P .. "/" .. APP, P .. "/" .. APP .. ".bak"
    local stage = P .. "/.tillandsias-install.stage"
    local prev, rf, rt = nil, nil, nil
    local function cleanup() -- the installer's EXIT/INT/TERM trap
        if rt and not scratch.exists(rt) and rf and scratch.exists(rf) then scratch.rename(rf, rt) end
        scratch.rm(stage)
    end
    scratch.mkdir(stage)
    extract_into(stage)
    if stop == 1 then return cleanup() end
    if scratch.exists(DEST) then
        if scratch.exists(BACKUP) then prev = BACKUP .. ".prev"; scratch.rename(BACKUP, prev) end
        rf, rt = BACKUP, DEST
        scratch.rename(DEST, BACKUP)
    end
    if stop == 2 then return cleanup() end
    scratch.rename(stage .. "/" .. APP, DEST)
    rf, rt = nil, nil
    if stop == 3 then return cleanup() end
    if prev then scratch.rm(prev) end
    cleanup()
end

-- The OLD sequence, for the negative control: no staging, no restore.
local function run_old(P, stop)
    local DEST, BACKUP = P .. "/" .. APP, P .. "/" .. APP .. ".bak"
    if scratch.exists(DEST) then scratch.rm(BACKUP); scratch.rename(DEST, BACKUP) end
    if stop == 2 then return end
    extract_into(P)
end

local P = new_prefix("p1"); run_fixed(P, 1)
T:arm("ARM 1: stopped after the staging extract, the OLD app is still in place", marker_of(P) == "OLD", marker_of(P))

P = new_prefix("p2"); run_fixed(P, 2)
local m = marker_of(P)
T:arm("ARM 2: stopped BETWEEN the renames, cleanup restored the app (not absent)", m == "OLD" or m == "NEW", m)

P = new_prefix("p3"); run_fixed(P, 3)
T:arm("ARM 3: stopped before the old backup is removed, the NEW app is in place", marker_of(P) == "NEW", marker_of(P))

P = new_prefix("p4"); run_fixed(P, 0)
T:arm("ARM 4: clean run, NEW app in place and the previous app kept as .bak",
    marker_of(P) == "NEW" and scratch.exists(P .. "/" .. APP .. ".bak"),
    "marker=" .. marker_of(P) .. " bak=" .. tostring(scratch.exists(P .. "/" .. APP .. ".bak")))
local _, dirs = scratch.list(P)
local staged = false
for _, n in ipairs(dirs) do if n:sub(1, 21) == ".tillandsias-install." then staged = true end end
T:arm("ARM 4: no staging directory left behind", not staged, table.concat(dirs, ","))

P = new_prefix("p5"); run_old(P, 2)
T:arm("ARM 5 NEGATIVE CONTROL: the OLD ordering leaves the destination ABSENT", marker_of(P) == "ABSENT", marker_of(P))

T:finish()
