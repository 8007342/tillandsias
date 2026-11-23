-- @trace order:2234-gmmc, spec:spec-traceability
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-cheatsheet-source-anchors.lua — a cheatsheet `sources:` anchor must name
-- the file that DECLARES the order, not one that merely mentions it. Drives
-- scripts/lua/check-cheatsheet-source-anchors.lua over a fixture cheatsheet
-- planted in cheatsheets/ for the run. Ported from
-- test-cheatsheet-source-anchors.sh (2234-gmmc).
--
--   a nonexistent file is caught                               (guard exit 1)
--   b an order declared nowhere is caught                      (1)
--   c a live-ledger anchor for an archived order is caught     (1)
--   d an anchor at the declaring file passes                   (0)
--   e sources without an order anchor are ignored              (0)
--
-- A guard already failing on this tree cannot attribute its own result: that
-- is a named skip, as is a missing runner.
--
-- Verdict: ok:cheatsheet-source-anchors-fixture:<n> passed
--        | violation:cheatsheet-source-anchors-fixture:<n> failed | skip:…

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    local rel0 = "target/plan-scratch/cheatsheet-anchors-resolve-" .. tostring(time.now_ms()) .. ".sh"
    fs.write(rel0, ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", root .. "/" .. rel0 } }.stdout or "")
    proc.run{ argv = { "find", root .. "/" .. rel0, "-delete" } }
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
local caps = RUNNER ~= "" and (proc.run{ argv = { RUNNER, "capabilities" } }.stdout or "") or ""
if not ("\n" .. caps):find("\nscript\n", 1, true) then
    verdict.skip("cheatsheet-source-anchors-fixture:no-script-runner — no tillandsias-plan with `script run` resolves; rebuild it (cargo build --release -p tillandsias-plan)")
end
local CHECK = root .. "/scripts/lua/check-cheatsheet-source-anchors.lua"

local FIXTURE = "cheatsheets/zz-anchor-fixture-" .. tostring(time.now_ms()) .. ".md"
local function cleanup() if fs.exists(FIXTURE) then proc.run{ argv = { "find", root .. "/" .. FIXTURE, "-delete" } } end end

local pass, failn = 0, 0
local function result(name, want, got)
    if want == got then pass = pass + 1
    else failn = failn + 1; log.raw("FAIL: " .. name .. " — expected exit " .. want .. ", got " .. tostring(got)) end
end
local function guard_exit()
    return proc.run{ argv = { RUNNER, "script", "run", CHECK }, cwd = root, timeout_ms = 120000 }.code
end
local function sheet(src) fs.write(FIXTURE, "sources:\n  - " .. src .. "\nauthority: high\n\n# fixture\n") end

local baseline = guard_exit()
if baseline ~= 0 then
    verdict.skip("cheatsheet-source-anchors-fixture:guard-already-failing — the anchor guard exits "
        .. tostring(baseline) .. " on this tree, so the fixture cannot attribute its own result")
end

sheet("openspec/specs/NOT-A-FILE.md order:9999-zzzz")
result("nonexistent file is caught", 1, guard_exit())
sheet("README.md order:9999-zzzz")
result("order declared nowhere is caught", 1, guard_exit())
sheet("plan/index.yaml order:804-ckst")
result("live-ledger anchor for an archived order is caught", 1, guard_exit())
sheet("plan/archive/packets-2026-08.yaml order:804-ckst")
result("anchor at the declaring file passes", 0, guard_exit())
fs.write(FIXTURE, "sources:\n  - some/free/text.md\nauthority: low\n")
result("sources without an order anchor are ignored", 0, guard_exit())

cleanup()
out.line("cheatsheet-source-anchor fixture: " .. pass .. " passed, " .. failn .. " failed")
if failn == 0 then verdict.ok("cheatsheet-source-anchors-fixture:" .. pass .. " passed") end
verdict.emit("violation:cheatsheet-source-anchors-fixture:" .. failn .. " failed", 1)
