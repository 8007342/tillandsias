-- @trace order:1404-4x3r, order:2207-vswc
--
-- test-drain-queue-bare-refuses.lua — PORTED from
-- test-drain-queue-bare-refuses.sh (2207-vswc), same arms, same lines.
--
-- drain-queue.sh claims a packet and launches a PAID agent session per ready
-- row. Run with no arguments it used to drain the whole queue: on yoga,
-- 2026-09-26, a bare run claimed packet 278 and ran codex for ~6 minutes.
--
-- NEVER run the real script bare to reproduce that. Every arm here runs a
-- COPY inside a scratch repo (under target/plan-scratch) whose ./repeat,
-- scripts/claim-ledger-node.sh and plan binary are stubs that only RECORD
-- being called. The script reaches both by relative path, so the copy cannot
-- touch the real ones.
--
-- ARM 1  a bare invocation is REFUSED, exits non-zero, names --drain, and the
--        record is EMPTY (no claim, no launch).
-- ARM 2  --dry-run alone still prints the plan and records nothing.
-- ARM 3  POSITIVE CONTROL: --drain --limit 1 claims and launches exactly once.
--        Without it, ARM 1 could pass because the stubs were unreachable.
--
-- Verdict: ok:drain-queue-bare-refuses:3 | violation:drain-queue-bare-refuses:<pass>/<total>

local DQ = "scripts/drain-queue.sh"
if not fs.exists(DQ) then verdict.skip("drain-queue-bare-fixture:script-absent") end

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local relW = "target/plan-scratch/drain-queue-" .. tostring(time.now_ms())
local W = root .. "/" .. relW
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end
local function oneline(s) return ((s or ""):gsub("\n+$", ""):gsub("\n", ";")) end

local function sandbox(name)
    local rel = relW .. "/" .. name
    local r, rec = W .. "/" .. name, W .. "/" .. name .. ".calls"
    proc.run{ argv = { "mkdir", "-p", r .. "/scripts", r .. "/plan" } }
    proc.run{ argv = { "cp", DQ, r .. "/scripts/drain-queue.sh" } }
    fs.write(relW .. "/" .. name .. ".calls", "")
    fs.write(rel .. "/repeat", '#!/bin/sh\necho "repeat $*" >> "' .. rec .. '"\nexit 0\n')
    fs.write(rel .. "/scripts/claim-ledger-node.sh",
        '#!/bin/sh\necho "claim-ledger-node $*" >> "' .. rec .. '"\necho "ok:$1:$2"\n')
    -- The plan binary answers the one query the script makes with one ready row.
    fs.write(rel .. "/fake-plan", '#!/bin/sh\nprintf "278\\tfixture-packet\\tv0.5\\tlinux\\n"\n')
    proc.run{ argv = { "chmod", "+x", r .. "/repeat", r .. "/scripts/claim-ledger-node.sh", r .. "/fake-plan" } }
    proc.run{ argv = { "git", "init", "-q", r } }
    return r, relW .. "/" .. name .. ".calls"
end
local function run(r, args)
    local a = { "bash", "scripts/drain-queue.sh" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    local p = proc.run{ argv = a, cwd = r, env = { TILLANDSIAS_PLAN_BIN = r .. "/fake-plan" }, stdin = "",
        timeout_ms = 120000 }
    return (p.stdout or "") .. (p.stderr or ""), p.code
end

-- --- ARM 1: bare is refused and spends nothing ----------------------------
local r1, c1 = sandbox("bare")
local out1, rc1 = run(r1, {})
local rec1 = fs.read(c1) or ""
if rc1 ~= 0 and rec1 == "" and out1:find("refused:drain-queue:bare-invocation", 1, true)
    and out1:find("--drain", 1, true) then
    ok("ARM 1 a bare invocation is refused (rc=" .. tostring(rc1) .. "), names --drain, and records no claim or launch")
else
    bad("ARM 1 a bare invocation was not refused (rc=" .. tostring(rc1) .. "); it would have run: " .. oneline(rec1))
end

-- --- ARM 2: --dry-run still prints the plan, spends nothing ---------------
local r2, c2 = sandbox("dry")
local out2, rc2 = run(r2, { "--dry-run" })
local rec2 = fs.read(c2) or ""
if rc2 == 0 and rec2 == "" and out2:find("[278] fixture-packet", 1, true) then
    ok("ARM 2 --dry-run prints the plan and records nothing")
else
    bad("ARM 2 --dry-run rc=" .. tostring(rc2) .. " record='" .. oneline(rec2) .. "'")
end

-- --- ARM 3: POSITIVE CONTROL, an explicit --drain reaches the stubs -------
local r3, c3 = sandbox("drain")
local _, rc3 = run(r3, { "--drain", "--limit", "1" })
local n_claim, n_repeat = 0, 0
for _, l in ipairs(text.lines(fs.read(c3) or "")) do
    if l:sub(1, 24) == "claim-ledger-node claim " then n_claim = n_claim + 1 end
    if l:sub(1, 7) == "repeat " then n_repeat = n_repeat + 1 end
end
if rc3 == 0 and n_claim == 1 and n_repeat == 1 then
    ok("ARM 3 --drain --limit 1 claims once and launches once")
else
    bad("ARM 3 --drain --limit 1 rc=" .. tostring(rc3) .. " claims=" .. n_claim .. " launches=" .. n_repeat)
end

proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 }
local total = pass + fail
if fail == 0 then verdict.emit("ok:drain-queue-bare-refuses:" .. pass, 0) end
verdict.emit("violation:drain-queue-bare-refuses:" .. pass .. "/" .. total, 1)
