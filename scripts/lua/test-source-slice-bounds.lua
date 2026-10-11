-- @trace order:797-8dzt, order:1588-bzre
--
-- test-source-slice-bounds.lua — PORTED from test-source-slice-bounds.sh
-- (1588-bzre). Fixture for scripts/check-source-slice-bounds.sh, through its
-- TILLANDSIAS_SLICE_BOUND_ROOT seam. Scenario 2 is the one that matters: it
-- FAILED on the guard's first draft, because a plain fixed-string search for
-- the needle found it inside the very `.split("…")` call under test, so every
-- bound resolved to itself and the guard was vacuous.
--
--   1 a bound naming a symbol that EXISTS passes (rc 0)
--   2 a bound naming a symbol that exists NOWHERE is caught (rc 1)
--   3 NEGATIVE CONTROL: a bound on a symbol declared in a SIBLING file of the
--     same crate (include_str! of another module) is not accused (rc 0)
--   4 READERS: the .sh's retired failure line (FAIL: source-slice-bounds ...)
--     has no reader in scripts/, the gate steps or the litmus specs; the count
--     of files searched is printed
--
-- Terminal line: ok:source-slice-bounds:<n> / refused:source-slice-bounds:<n>
-- (1588-bzre: the .sh printed `ok: source-slice-bounds 3/3` and `FAIL: ...`;
-- it had no live caller, so nothing read either).

local GUARD = "scripts/check-source-slice-bounds.sh"
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/slice-bounds-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local SB = ROOT .. "/" .. REL
fs.mkdir(REL .. "/mycrate/src")
fs.write(REL .. "/mycrate/Cargo.toml", "")
local LIB = REL .. "/mycrate/src/lib.rs"

local passed, failed = 0, 0
local function check(name, want, got)
    if want == got then out.line("ok: " .. name); passed = passed + 1
    else out.line("FAIL: " .. name .. " — want rc=" .. want .. " got rc=" .. got); failed = failed + 1 end
end
local function guard()
    local r = proc.run({ argv = { "bash", GUARD }, env = { TILLANDSIAS_SLICE_BOUND_ROOT = SB }, timeout_ms = 120000 })
    return (r.status == "exited") and r.code or -1
end
local function replace(old, new)
    local body = fs.read(LIB)
    local s, e = string.find(body, old, 1, true)
    if s == nil then return false end
    fs.write(LIB, body:sub(1, s - 1) .. new .. body:sub(e + 1))
    return true
end

-- 1. A bound naming a symbol that EXISTS must pass.
fs.write(LIB, 'fn real_one() {}\nfn other() {}\n#[test]\nfn t() { let s = include_str!("lib.rs"); let _ = s.split("fn real_one").nth(1); }\n')
check("live-bound-passes", 0, guard())

-- 2. A bound naming a symbol that exists NOWHERE must be caught.
if replace('s.split("fn real_one")', 's.split("fn vanished_neighbour")') then
    check("dead-bound-is-caught", 1, guard())
else check("dead-bound-is-caught (the edit landed)", 0, 1) end

-- 3. NEGATIVE CONTROL: a bound on a sibling file's symbol is not accused.
fs.write(REL .. "/mycrate/src/other.rs", "pub fn helper_symbol() {}\n")
if replace('s.split("fn vanished_neighbour")', 's.split("pub fn helper_symbol")') then
    check("cross-file-bound-not-accused", 0, guard())
else check("cross-file-bound-not-accused (the edit landed)", 0, 1) end

-- 4. The retired failure line, assembled so this file cannot match itself.
local NEEDLE = "FA" .. "IL: source-slice-bounds"
local SELF = "scripts/lua/test-source-slice-bounds.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and text.contains(body, NEEDLE) then hits[#hits + 1] = f end
        end
    end
end
if #hits == 0 and searched > 100 then
    out.line("ok: the retired FAIL: terminal line has 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
    passed = passed + 1
else
    out.line("FAIL: readers of the retired FAIL: line: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
    failed = failed + 1
end

proc.run({ argv = { "rm", "-rf", SB } })
if failed == 0 then verdict.emit("ok:source-slice-bounds:" .. passed, 0) end
verdict.emit("refused:source-slice-bounds:" .. failed, 1)
