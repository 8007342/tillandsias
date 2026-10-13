-- @trace order:1631-6w8z
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-fragment-events-land.lua — every event in the overlay must attach to a
-- packet that exists.
--
-- WHY THIS EXISTS. On 2026-08-23 a coordinator finding was filed against
-- `macos-onboarding-defect-sweep`. The packet is
-- `macos-host-onboarding-defect-sweep` — one word short. The fold refused to
-- consume the fragment, correctly and loudly, on EVERY compaction for fourteen
-- hours. Three separate cycle reports across two hosts read that refusal and
-- classified it as a benign permanent refusal awaiting a tombstone. It was a
-- real event attached to nothing, and no reader of 851-gpb5 ever saw it.
--
-- A misfiled packet_id is SILENT DATA LOSS WEARING THE COSTUME OF TIDY
-- BOOKKEEPING. Nothing is corrupted, nothing fails, the file is even preserved
-- — and the record is invisible.
--
-- REUSES THE FOLD'S OWN JOIN rather than recomputing it. `compact --dry-run`
-- already resolves every event's packet_id against the merged fold and reports
-- what it could not place. This asserts on that output and writes nothing
-- (--dry-run is REQUIRED: a gate that mutates what it inspects is not one).
--
-- FRESHNESS IS THE CALLER'S, NOT THIS SCRIPT'S. Ported from
-- scripts/check-fragment-events-land.sh (the shell-to-lua carry paid by
-- 1631-6w8z). The .sh called ensure_fresh_plan_binary before `compact`, so it
-- vouched for its own binary. This runs INSIDE a tillandsias-plan, and a stale
-- binary cannot judge its own currency, so the gate's call site runs
-- ensure_fresh_plan_binary first and hands the fresh binary in (the door
-- refuses a stale plan binary before any guard runs). This script asks the
-- binary it is handed.
--
-- GRAMMAR (one line on stdout; the exit codes are the .sh's)
--   ok:fragment-events-land:<n> fragment(s) checked                       exit 0
--   blocked:fragment-events-land:<n> event(s) attached to no packet       exit 1
--   could-not-run:fragment-events-land:no-plan-binary                     exit 2
--   could-not-run:fragment-events-land:compact-did-not-run                exit 2
--
-- Usage: tillandsias-plan script run scripts/lua/check-fragment-events-land.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.emit("could-not-run:fragment-events-land:no-checkout", 2, "git rev-parse --show-toplevel did not answer")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then
    verdict.emit("could-not-run:fragment-events-land:no-plan-binary", 2,
        "TILLANDSIAS_SCRIPT_RUNNER_BIN is unset, so no fold can be asked; run it through build.sh or _run_lua_decider")
end

local n = 0
for _, f in ipairs(fs.list(ROOT .. "/plan/index.d")) do
    if f:match("%.yaml$") then n = n + 1 end
end
if n == 0 then verdict.emit("ok:fragment-events-land:0 fragment(s) checked", 0) end

local r = proc.run({ argv = { PLAN, "compact", "--dry-run" }, cwd = ROOT, timeout_ms = 600000 })
if r.status ~= "exited" then
    verdict.emit("could-not-run:fragment-events-land:compact-did-not-run", 2,
        PLAN .. " compact --dry-run did not exit (" .. tostring(r.status) .. ")")
end
local lines = text.lines((r.stdout or "") .. "\n" .. (r.stderr or ""))
local orphans = 0
for i, l in ipairs(lines) do
    if l:find("NO SUCH PACKET", 1, true) then
        orphans = orphans + 1
        if i > 1 then log.raw(lines[i - 1]) end
        log.raw(l)
    end
end
if orphans > 0 then
    log.raw("  An event on a nonexistent packet is INVISIBLE, not merely unfolded:")
    log.raw("  the fragment survives, compaction reports it forever, and no reader")
    log.raw("  of any packet ever sees the record. Re-file it under the correct id.")
    verdict.emit("blocked:fragment-events-land:" .. orphans .. " event(s) attached to no packet", 1)
end
verdict.emit("ok:fragment-events-land:" .. n .. " fragment(s) checked", 0)
