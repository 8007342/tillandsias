-- @trace order:1928-s9ae, order:2080-zcur
--
-- test-spawn-program-captured-before-spawn.lua — in the headless launcher the
-- program name is captured (`let program = command`) BEFORE the spawn that
-- consumes the command, WITHIN the same function, so a spawn failure can name
-- what it tried. The property is judged per function, not by whole-file line
-- order.
--   1 within its function the program is captured before the spawn
--   2 the retired whole-file position check refuses on today's file though
--     the property holds (why it was retired)
--   3 negative control: a mutant with the capture moved after its spawn is refused
-- Keeps the established verdict line the litmus greps:
--   ok: program captured before spawn (<n>/<n>, 1928-s9ae)
-- Ported from scripts/test-spawn-program-captured-before-spawn.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spawn-program-captured-before-spawn.lua

local fixture = require "common.fixture"
local T = fixture.new("spawn-program-captured-before-spawn")
local FN = [[^\s*(pub(\([a-z]+\))? )?(async )?fn [A-Za-z0-9_]+]]
local SPAWN, CAPTURE = "spawn_caller_owned_lifetime()", "let program = command"

local function property(lines)
    local fnline, seen_spawn, p, pfn, pre, s = 0, false, nil, nil, false, nil
    for i, l in ipairs(lines) do
        if text.is_match(l, FN) then fnline = i; seen_spawn = false end
        if l:find(SPAWN, 1, true) then
            if p and i > p and not s and fnline == pfn then s = i end
            if not p then seen_spawn = true end
        end
        if not p and l:find(CAPTURE, 1, true) then p = i; pfn = fnline; pre = seen_spawn end
    end
    if not p then return "fail:no-capture" end
    if pre then return "fail:spawn-before-capture-in-fn" end
    if not s then return "fail:no-spawn-after-capture-in-fn" end
    return "ok:" .. p .. ":" .. s
end

local lines = text.lines(fs.read("crates/tillandsias-headless/src/main.rs") or "")
local v = property(lines)
T:arm("within its function the program is captured before the spawn", text.starts_with(v, "ok:"), v)

local fp, fs_ = nil, nil
for i, l in ipairs(lines) do
    if not fp and l:find(CAPTURE, 1, true) then fp = i end
    if not fs_ and l:find(SPAWN, 1, true) then fs_ = i end
end
T:arm("the retired whole-file position check refuses on today's file though the property holds",
    not (fp and fs_ and fp < fs_), "it passes — arm 2 has no subject (p=" .. tostring(fp) .. " s=" .. tostring(fs_) .. ")")

local sl
for i = (fp or 0) + 1, #lines do
    if lines[i]:find(SPAWN, 1, true) then sl = i; break end
end
local mutant = {}
for i, l in ipairs(lines) do
    if i ~= fp then mutant[#mutant + 1] = l end
    if i == sl then mutant[#mutant + 1] = lines[fp] end
end
local mv = (fp and sl) and property(mutant) or "no-mutant"
T:arm("negative control: the capture moved after its spawn is refused", text.starts_with(mv, "fail:"), mv)

T:finish{
    ok = function(p) return "ok: program captured before spawn (" .. p .. "/" .. p .. ", 1928-s9ae)" end,
}
