-- @env PATH HOME
-- @trace order:1247-9pr8, order:2251-4xvd, order:2279-jbsd
--
-- test-preflight-stale-plan-binary.lua — ./build.sh --preflight asks the plan
-- binary for its currency ONCE, up front, and refuses by name when it is
-- stale, instead of letting every guard that resolves it refuse under its own
-- name. Measured on yolanda 2026-09-28 (1462-trch): four unrelated-looking
-- refusals, no mention of the binary. Ported from
-- scripts/test-preflight-stale-plan-binary.sh (order 2251-4xvd pays the
-- carried shell-to-lua item); same five arms and verdict line.
--
-- The whole door takes minutes, so this cuts the check out of build.sh between
-- its exact-once markers and runs THAT TEXT against stub binaries supplied
-- through TILLANDSIAS_PLAN_BIN (the probe's own override). A SCRIPT_DIR pointing
-- at this checkout supplies the real probe.
--
--   1  stale stub     -> ONE refused:preflight:stale-plan-binary line, WHY and
--                        REMEDY lines, rc 1, and nothing after the block runs
--   2  current stub   -> no refusal; the block falls through (rc 0)
--   3  mute stub      -> an old binary that cannot answer is NOT refused
--   4  no binary      -> ONE could-not-run:preflight:no-classifier line carrying
--                        the build remedy, rc 3, nothing after it runs (2279-jbsd;
--                        this arm used to pin "no refusal")
--   6  fresh tree     -> the same, through the REAL probe: a tree holding only the
--                        probe, no override, no plan binary on PATH. The door
--                        before 2279-jbsd (the new block removed) falls through
--                        with rc 0, so the arm measures the change
--   5  markers        -> each marker occurs exactly once, in that order
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-stale-plan-binary.lua
-- Verdict: ok:preflight-stale-plan-binary:<p>/<n> | violation:preflight-stale-plan-binary:<p>/<n>

local fixture = require "common.fixture"
local root = fixture.repo_root()
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

-- 5
local lines = text.lines(fs.read("build.sh") or "")
local nb, ne, lb, le = 0, 0, nil, nil
for i, l in ipairs(lines) do
    if l:find("BEGIN-STALE-PLAN-BINARY-CHECK", 1, true) then nb = nb + 1; lb = lb or i end
    if l:find("END-STALE-PLAN-BINARY-CHECK", 1, true) then ne = ne + 1; le = le or i end
end
if nb == 1 and ne == 1 and lb < le then
    ok("arm 5: markers exactly once, in order (lines " .. lb .. ".." .. le .. ")")
else
    bad("arm 5: markers begin=" .. nb .. " end=" .. ne .. " at " .. tostring(lb or "?") .. ".." .. tostring(le or "?"))
    verdict.emit("violation:preflight-stale-plan-binary:" .. pass .. "/" .. (pass + fail), 1)
end

local REL = "target/plan-scratch/preflight-stale-plan-binary-" .. tostring(time.now_ms())
local W = root .. "/" .. REL
fs.mkdir(REL)
local block = { 'SCRIPT_DIR="$1"' }
for i = lb, le do block[#block + 1] = lines[i] end
block[#block + 1] = 'echo "fell-through"'
fs.write(REL .. "/block.sh", table.concat(block, "\n") .. "\n")

local function mkstub(name, body)
    fs.write(REL .. "/" .. name, "#!/usr/bin/env bash\n" .. body .. "\n")
    proc.run({ argv = { "chmod", "+x", W .. "/" .. name }, timeout_ms = 10000 })
end
mkstub("stale", 'echo "stale:validator-surface built-from=aaaa checkout=bbbb" >&2; exit 3')
mkstub("current", 'echo "ok:validator-surface:bbbb"; exit 0')
mkstub("mute", "exit 2")
-- ORDER 2186-x5kv: the block now rebuilds a stale binary once; a planted cargo
-- that fails keeps the real one from running and leaves the stub stale.
mkstub("cargo", "exit 101")

local function run(bin)
    local r = proc.run({ argv = { fixture.posix_shell(), W .. "/block.sh", root }, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"),
                TILLANDSIAS_PREFLIGHT_CARGO = W .. "/cargo", TILLANDSIAS_PLAN_BIN = bin } })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function count_prefix(o, p)
    local n = 0
    for _, l in ipairs(text.lines(o)) do if l:sub(1, #p) == p then n = n + 1 end end
    return n
end

-- 1
local rc, o = run(W .. "/stale")
local n = count_prefix(o, "refused:preflight:stale-plan-binary")
if rc == 1 and n == 1 and has(o, "REMEDY: the door already ran cargo build --release -p tillandsias-plan once")
    and has(o, "WHY:") and not has(o, "fell-through") then
    ok("arm 1: a stale binary gives ONE named refusal with WHY and REMEDY, rc 1, nothing after it runs")
else
    bad("arm 1: rc=" .. tostring(rc) .. " refusals=" .. n .. " out=[" .. o .. "]")
end
-- 2, 3: each falls through with no refusal
for _, a in ipairs({
    { "current", "arm 2: a current binary falls through, no refusal" },
    { "mute", "arm 3: a binary too old to answer is not refused" },
}) do
    rc, o = run(W .. "/" .. a[1])
    if rc == 0 and has(o, "fell-through") and not has(o, "refused:") then ok(a[2])
    else bad(a[2]:match("^(arm %d)") .. ": rc=" .. tostring(rc) .. " out=[" .. o .. "]") end
end

-- 4
local NC = "could-not-run:preflight:no-classifier"
local function no_classifier(c, o2)
    local l
    for _, x in ipairs(text.lines(o2)) do if x:sub(1, #NC) == NC then l = x end end
    return c == 3 and count_prefix(o2, NC) == 1 and l:find("cargo build --release -p tillandsias-plan", 1, true) ~= nil
        and not has(o2, "fell-through")
end
rc, o = run(W .. "/absent-binary")
if no_classifier(rc, o) then ok("arm 4: no binary is could-not-run:no-classifier with its remedy on the line, rc 3")
else bad("arm 4: rc=" .. tostring(rc) .. " out=[" .. o .. "]") end
-- 6
fs.mkdir(REL .. "/fresh/scripts")
fs.write(REL .. "/fresh/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
local body = fs.read(REL .. "/block.sh")
local a, b = body:find("    # ORDER 2279%-jbsd.-\n    fi\n")
fs.write(REL .. "/block-old.sh", a and (body:sub(1, a - 1) .. body:sub(b + 1)) or "exit 99\n")
local function fresh(name)
    local r = proc.run({ argv = { fixture.posix_shell(), W .. "/" .. name, W .. "/fresh" }, timeout_ms = 60000,
        -- the runtime hands an ambient TILLANDSIAS_PLAN_BIN down; empty is unset to the probe
        env = { PATH = "/usr/bin:/bin", HOME = W .. "/fresh", TILLANDSIAS_PLAN_BIN = "", CARGO_TARGET_DIR = "" } })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local c1, o1 = fresh("block.sh")
local c0, o0 = fresh("block-old.sh")
if no_classifier(c1, o1) and c0 == 0 and has(o0, "fell-through") then
    ok("arm 6: a fresh tree with no plan binary on PATH exits 3; the door before this fell through with 0")
else
    bad("arm 6: rc=" .. tostring(c1) .. " out=[" .. o1 .. "] before: rc=" .. tostring(c0) .. " out=[" .. o0 .. "]")
end

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 60000 })
local total = pass + fail
if fail == 0 then verdict.emit("ok:preflight-stale-plan-binary:" .. pass .. "/" .. total, 0) end
verdict.emit("violation:preflight-stale-plan-binary:" .. pass .. "/" .. total, 1)
