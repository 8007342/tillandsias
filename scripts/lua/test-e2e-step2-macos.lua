-- @trace order:1181-bkem, order:2108-hmfx
--
-- test-e2e-step2-macos.lua — hermetic fixture for scripts/e2e-step2-macos.sh.
-- Ported from scripts/test-e2e-step2-macos.sh (2108-hmfx) onto the scratch.*
-- door, with the same five arms. HOME is a scratch dir for each arm, so no real
-- tray, no real Application Support or Caches state, and no podman is touched.
--
--   1 TILLANDSIAS_RESET_KEEP_MODELS=1 spares models/ byte-identical and wipes
--     everything else (the VM dir and the other cache files).
--   2 With the flag unset, everything is wiped, as before.
--   3 MUTATION CONTROL: a copy of the script with the sparing construct
--     stripped (the `! -name models` branch replaced by an unconditional
--     rm -rf "$CACHE_DIR") reds arm 1's property under the same flag. The
--     mutant is proven different from the original, and a no-op strip is
--     proven identical.
--   4 RESIDUE NEGATIVE: a copy with the flag-unset rm -rf "$CACHE_DIR" removed
--     leaves CACHE_DIR behind, so the script must print FAIL: residue, name the
--     path, and exit 1.
--   5 Flag set but no models/ dir: a plain destroy with no empty cache dir left
--     behind, and a line saying nothing was spared.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-e2e-step2-macos.lua
-- GRAMMAR ok:e2e-step2-macos:5 (exit 0) | violation:e2e-step2-macos:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("e2e-step2-macos")

local SUT_REL = "scripts/e2e-step2-macos.sh"
if not fs.exists(SUT_REL) then T:refuse("no-sut", "no " .. SUT_REL) end
local SUT = fixture.repo_root() .. "/" .. SUT_REL
local SRC = fs.read(SUT_REL)

local VM = "/Library/Application Support/tillandsias"
local CACHE = "/Library/Caches/tillandsias"
-- Deterministic stand-ins for the random bytes the shell fixture used: the
-- property is "byte-identical", so any fixed, distinctive content serves.
local WEIGHTS = string.rep("weights-0123456789abcdef\0\255", 80)

-- A fresh fake HOME with a VM dir and a cache dir carrying models/weights.bin,
-- a non-model file and a subdirectory. Returns the scratch dir.
local function seed_home(tag, with_models)
    local d = T:scratch(tag)
    scratch.mkdir(d.leaf .. "/home" .. VM)
    scratch.write(d.leaf .. "/home" .. VM .. "/rootfs.img", string.rep("r", 1024))
    scratch.mkdir(d.leaf .. "/home" .. CACHE .. "/sub")
    if with_models ~= false then
        scratch.mkdir(d.leaf .. "/home" .. CACHE .. "/models")
        scratch.write(d.leaf .. "/home" .. CACHE .. "/models/weights.bin", WEIGHTS)
    end
    scratch.write(d.leaf .. "/home" .. CACHE .. "/other.bin", string.rep("o", 64))
    scratch.write(d.leaf .. "/home" .. CACHE .. "/sub/x", "x")
    scratch.mkdir(d.leaf .. "/log")
    return d
end

local function run_sut(script_abs, d, keep)
    local env = { PATH = "/usr/bin:/bin:/usr/sbin:/sbin", HOME = d.abs .. "/home" }
    if keep then env.TILLANDSIAS_RESET_KEEP_MODELS = "1" end
    local r = proc.run{ argv = { "bash", script_abs, d.abs .. "/log" }, env = env, timeout_ms = 60000 }
    local rc = (r.status == "exited") and r.code or -1
    return rc, (r.stdout or "") .. (r.stderr or "")
end

local function has(s, needle) return text.contains(s, needle) end
local function gone(d, p) return not scratch.exists(d.leaf .. "/home" .. p) end
local function residue(d)
    local p = d.leaf .. "/log/02-macos-residue.txt"
    return scratch.exists(p) and scratch.read(p) or ""
end

-- A copy of the script with each line passed through `edit`, written beside
-- the arm's HOME. Returns its absolute path and its text.
local function mutant(d, name, edit)
    local outl = {}
    for _, l in ipairs(text.lines(SRC)) do outl[#outl + 1] = edit(l) end
    local body = table.concat(outl, "\n") .. "\n"
    scratch.write(d.leaf .. "/" .. name, body)
    return d.abs .. "/" .. name, body
end

-- Arm 1: flag set — models/ survives byte-identical, everything else gone.
do
    local d = seed_home("keep")
    local rc, o = run_sut(SUT, d, true)
    local w = d.leaf .. "/home" .. CACHE .. "/models/weights.bin"
    local res = residue(d)
    local offending = res:gsub("^[^\n]*\n?", "")
    local why = {}
    if rc ~= 0 then why[#why + 1] = "exit " .. rc end
    if not gone(d, VM) then why[#why + 1] = "VM_DIR survived" end
    if not (scratch.exists(w) and scratch.read(w) == WEIGHTS) then why[#why + 1] = "weights.bin missing or changed" end
    if not gone(d, CACHE .. "/other.bin") then why[#why + 1] = "other.bin survived" end
    if not gone(d, CACHE .. "/sub") then why[#why + 1] = "sub/ survived" end
    if not has(o, "keep-models: spared " .. d.abs .. "/home" .. CACHE .. "/models") then why[#why + 1] = "no keep-models line naming the path" end
    if not has(o, "ok:e2e-step2-macos:destroyed:kept-models") then why[#why + 1] = "no kept-models verdict" end
    if text.trim(offending) ~= "" then why[#why + 1] = "residue names offending paths: " .. res end
    T:arm("1 the flag spares models/ byte-identical and wipes the rest", #why == 0,
        table.concat(why, "; ") .. " | " .. o)
end

-- Arm 2: flag unset — everything gone.
do
    local d = seed_home("wipe")
    local rc, o = run_sut(SUT, d, false)
    T:arm("2 with the flag unset everything is wiped",
        rc == 0 and gone(d, VM) and gone(d, CACHE)
            and has(o, "ok:e2e-step2-macos:destroyed") and not has(o, "kept-models"),
        "rc=" .. rc .. " | " .. o)
end

-- Arm 3: mutation control — the sparing construct stripped from the content.
do
    local d = seed_home("mut-spare")
    local applied = 0
    local m = mutant(d, "mutant-strip-spare.sh", function(l)
        if l:find("-maxdepth 1 ! -name models -exec rm -rf", 1, true) then
            applied = applied + 1
            return '    rm -rf "$CACHE_DIR"'
        end
        return l
    end)
    local noop_applied = 0
    local _, noop = mutant(d, "noop-strip.sh", function(l)
        if l:find("this-pattern-matches-nothing-in-the-real-script", 1, true) then noop_applied = noop_applied + 1 end
        return l
    end)
    local rc, o = run_sut(m, d, true)
    local w = d.leaf .. "/home" .. CACHE .. "/models/weights.bin"
    -- text.lines drops a trailing newline, so compare against a normalised original.
    local normal = table.concat(text.lines(SRC), "\n") .. "\n"
    T:arm("3 a mutant without the sparing loses models/ under the flag (mutant differs, no-op is identical)",
        applied > 0 and noop_applied == 0 and noop == normal and not scratch.exists(w),
        "applied=" .. applied .. " noop_identical=" .. tostring(noop == normal) .. " rc=" .. rc .. " | " .. o)
end

-- Arm 4: residue negative — the flag-unset cache rm dropped from the content.
do
    local d = seed_home("mut-residue")
    local applied = 0
    local m = mutant(d, "mutant-drop-cache-rm.sh", function(l)
        if l == '  rm -rf "$CACHE_DIR"' then applied = applied + 1; return "  :" end
        return l
    end)
    local rc, o = run_sut(m, d, false)
    T:arm("4 a mutant that leaves CACHE_DIR behind prints FAIL: residue, names it, exits 1",
        applied > 0 and rc == 1 and has(o, "FAIL: residue")
            and has(residue(d), d.abs .. "/home" .. CACHE),
        "applied=" .. applied .. " rc=" .. rc .. " | " .. o)
end

-- Arm 5: flag set but no models/ dir — plain destroy, nothing left as residue.
do
    local d = seed_home("nomodels", false)
    local rc, o = run_sut(SUT, d, true)
    T:arm("5 the flag with no models/ destroys everything and says nothing was spared",
        rc == 0 and gone(d, VM) and gone(d, CACHE) and has(o, "keep-models: nothing to spare")
            and has(o, "ok:e2e-step2-macos:destroyed") and not has(o, "kept-models"),
        "rc=" .. rc .. " | " .. o)
end

T:finish()
