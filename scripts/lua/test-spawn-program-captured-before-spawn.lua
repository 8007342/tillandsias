-- @trace spec:init-command
-- @trace order:1928-s9ae, order:2302-pspt
--
-- litmus:spawn-failure-names-program asks "is the program name captured BEFORE
-- the spawn". It once compared the FIRST `let program = command` with the FIRST
-- `spawn_caller_owned_lifetime()` anywhere in main.rs; 5f8cce30d (1911-3dqo)
-- added an unrelated caller-owned spawn earlier in the file and the step went
-- red while the property still held. The property is about ONE function:
-- within the function that captures the program, the capture precedes that
-- function's spawn. Ported from test-spawn-program-captured-before-spawn.sh.
--
--   1 the property: inside the enclosing fn of `let program = command`, a
--     spawn_caller_owned_lifetime() follows the capture and none precedes it
--   2 the retired whole-file position check REFUSES on today's file, so this
--     fixture is not a no-op relabelling of it
--   3 negative control: the capture moved after its spawn fails the property
--
-- GRAMMAR ok:spawn-program-captured-before-spawn:3 arms | violation:…:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("spawn-program-captured-before-spawn")
local F = "crates/tillandsias-headless/src/main.rs"

local CAPTURE, SPAWN = "let program = command", "spawn_caller_owned_lifetime()"
local function is_fn(l)
    local s = l:gsub("^%s+", "")
    s = s:gsub("^pub%([a-z]+%) ", ""):gsub("^pub ", ""):gsub("^async ", "")
    return s:match("^fn [%w_]+") ~= nil
end
local function has(l, s) return l:find(s, 1, true) ~= nil end

-- The .sh's awk, line for line: "ok:<p>:<s>" or "fail:<reason>".
local function property(lines)
    local fnline, seen_spawn, p, pfn, pre, s = 0, false, nil, nil, false, nil
    for n, l in ipairs(lines) do
        if is_fn(l) then fnline = n; seen_spawn = false end
        if has(l, SPAWN) then
            if p and n > p and not s and fnline == pfn then s = n end
            if not p then seen_spawn = true end
        end
        if has(l, CAPTURE) and not p then p = n; pfn = fnline; pre = seen_spawn end
    end
    if not p then return "fail:no-capture" end
    if pre then return "fail:spawn-before-capture-in-fn" end
    if not s then return "fail:no-spawn-after-capture-in-fn" end
    return "ok:" .. p .. ":" .. s
end

local lines = text.lines(fs.read(F))
local v = property(lines)
T:arm("1 within its function the program is captured (line " .. v:gsub("^ok:", "") .. ") before the spawn",
    v:match("^ok:") ~= nil, v)

local first_p, first_s
for n, l in ipairs(lines) do
    if not first_p and has(l, CAPTURE) then first_p = n end
    if not first_s and has(l, SPAWN) then first_s = n end
end
T:arm("2 the retired whole-file position check refuses on today's file (first capture "
        .. tostring(first_p) .. ", first spawn " .. tostring(first_s) .. ") though the property holds",
    not (first_p and first_s and first_p < first_s),
    "the retired check passes on today's file — arm 2 has no subject")

-- Mutant: drop the capture line and re-insert it after the spawn line it guards.
local mutant, held, sl = {}, nil, nil
for n, l in ipairs(lines) do
    if first_p and n > first_p and not sl and has(l, SPAWN) then sl = n end
end
for n, l in ipairs(lines) do
    if n == first_p then held = l else
        mutant[#mutant + 1] = l
        if n == sl then mutant[#mutant + 1] = held end
    end
end
local mv = property(mutant)
T:arm("3 negative control: the capture moved after its spawn is refused (" .. mv .. ")", mv:match("^fail:") ~= nil, mv)

T:finish()
