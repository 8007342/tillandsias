-- @env HOME
-- @trace order:1315-d4qd, order:2109-umac
--
-- test-reset-state-no-home-refusal.lua — ORDER 1315-d4qd: a destructive path
-- has no silent default. Ported from scripts/test-reset-state-no-home-refusal.sh
-- (2109-umac), with the same seven arms; its mutation arm now works on the
-- source text in memory, where the shell copied it to a mktemp dir.
--
-- With HOME unset, image_root resolves to /tmp/Library/Application Support/
-- tillandsias. For a READER that is a defensible answer, but it must SAY which
-- question it answered (MEASURED on macneo 2026-09-20: rootfs_present=false over
-- 1.2 GiB of real guest state). For a DESTRUCTIVE caller there is no defensible
-- default: --reset-state builds its announcement from the root it removes from,
-- so with the fallback both halves are wrong together. The refusal must
-- therefore precede the ANNOUNCEMENT, not just the deletion.
--
--   1-2 the real binary labels its fallback with HOME unset, and reports
--       source=home with HOME set (control); a NAMED skip off darwin or unbuilt
--   3   refusal precedes announcement precedes destruction (source order)
--   4   the destructive resolver returns Result and names its refusal
--   5   the reader still answers infallibly
--   6   status_item carries no second /tmp fallback
--   7   MUTATION: removing the refusal makes arm 3 unable to find it
--
-- USAGE   tillandsias-plan script run scripts/lua/test-reset-state-no-home-refusal.lua
-- GRAMMAR ok:reset-state-no-home-refusal:<n> (exit 0) | violation:...:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("reset-state-no-home-refusal")

local SRC_REL = "crates/tillandsias-macos-tray/src/reset_state.rs"
local DIAG_REL = "crates/tillandsias-macos-tray/src/diagnose.rs"
local STATUS_REL = "crates/tillandsias-macos-tray/src/status_item.rs"
for _, p in ipairs({ SRC_REL, DIAG_REL, STATUS_REL }) do
    if not fs.exists(p) then T:refuse("missing-source", "no " .. p) end
end
local SRC, DIAG = fs.read(SRC_REL), fs.read(DIAG_REL)

-- ARMS 1-2: the label, run against the REAL binary.
local TRAY = fixture.repo_root() .. "/target/debug/tillandsias-tray"
local uname = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
if uname ~= "Darwin" or not fs.exists("target/debug/tillandsias-tray") then
    -- NAMED SKIP (965-sxec): elsewhere that path is a DIFFERENT crate's binary
    -- of the same name (measured on macuahuitl 2026-09-21).
    out.line("SKIP(tray-not-built-or-not-darwin): ARMS 1-2 need target/debug/tillandsias-tray on macOS; NOT a pass")
else
    local BASE = { PATH = "/usr/bin:/bin:/usr/sbin:/sbin" }
    -- The runner's child env always inherits HOME, and the door has no unset,
    -- so `env -u HOME` (what the shell ran) is the launcher.
    local unset = proc.run{ argv = { "/usr/bin/env", "-u", "HOME", TRAY, "--diagnose", "--json" },
        env = BASE, timeout_ms = 120000 }
    T:arm("ARM1 with HOME unset, --diagnose LABELS its fallback root",
        text.contains(unset.stdout or "", '"image_root_source": "fallback:/tmp:HOME-unset"'),
        "no fallback label in --diagnose output with HOME unset")
    -- CONTROL: without it, ARM 1 would pass with the field hard-coded.
    local set = proc.run{ argv = { TRAY, "--diagnose", "--json" },
        env = { PATH = BASE.PATH, HOME = env.get("HOME") }, timeout_ms = 120000 }
    T:arm("ARM2 CONTROL: with HOME set the same binary reports source=home",
        text.contains(set.stdout or "", '"image_root_source": "home"'), "HOME is set but source is not 'home'")
end

-- The 1-based line number of the first line containing `needle` that is not a
-- `//` comment (the shell's `grep -n | grep -v '^\s*//' | head -1`).
local function first_line(src, needle, plain_prefix)
    for i, l in ipairs(text.lines(src)) do
        local hit = plain_prefix and (l:sub(1, #needle) == needle) or l:find(needle, 1, true)
        if hit and not l:find("^%s*//") then return i end
    end
    return nil
end

-- ARM 3: the refusal precedes the ANNOUNCEMENT. Source order, deliberately: a
-- test that only checked "nothing was deleted" would pass a version that
-- announced /tmp paths and then refused, which is already the false report.
local R = first_line(SRC, "image_root_for_destruction()")
local A = first_line(SRC, "announce_reset_plan(&d, &p)")
local D = first_line(SRC, "    apply_soft_reset(", true) -- 1437-8c6p: SOFT's first destructive call
T:arm("ARM3 refusal precedes announcement precedes destruction",
    R and A and D and R < A and A < D,
    "refusal=" .. tostring(R) .. " announce=" .. tostring(A) .. " destroy=" .. tostring(D))

-- ARM 4-5: the destructive resolver refuses; the reader does not.
T:arm("ARM4 the destructive resolver returns Result and names its refusal",
    text.contains(DIAG, "fn image_root_for_destruction() -> Result<PathBuf, String>")
        and text.contains(DIAG, "refused:reset-state:no-home"),
    "image_root_for_destruction is missing or does not name refused:reset-state:no-home")
local reader = false
for _, l in ipairs(text.lines(DIAG)) do
    if l:sub(1, 37) == "pub(crate) fn image_root() -> PathBuf" or l:sub(1, 25) == "    resolve_image_root().0" then
        reader = true
    end
end
T:arm("ARM5 the READER still answers infallibly", reader, "the reader path no longer answers infallibly")

-- ARM 6: the twin is gone (the LIVE TRAY reads status_item).
T:arm("ARM6 status_item delegates to the single resolver",
    not text.contains(fs.read(STATUS_REL), 'PathBuf::from("/tmp")'),
    "status_item still carries its own /tmp fallback: two copies of one rule")

-- ARM 7: MUTATION. ARM 3 is a line-order check and would pass trivially if its
-- finds stopped matching, so reproduce the defect in a copy and require ARM 3's
-- probe to lose the refusal.
local FROM, TO = "crate::diagnose::image_root_for_destruction()?", "crate::diagnose::image_root()"
local s = SRC:find(FROM, 1, true)
-- Like the shell's sed (no /g): the first occurrence on every line.
local ml = {}
for _, l in ipairs(text.lines(SRC)) do
    local a, b = l:find(FROM, 1, true)
    ml[#ml + 1] = a and (l:sub(1, a - 1) .. TO .. l:sub(b + 1)) or l
end
local mutated = table.concat(ml, "\n")
local MR = first_line(mutated, "image_root_for_destruction()")
T:arm("ARM7 MUTATION: removing the refusal makes ARM3 unable to find it", s ~= nil and MR == nil,
    s and ("the mutation left the refusal at line " .. tostring(MR)) or "the mutation target is gone from reset_state.rs")

T:finish()
