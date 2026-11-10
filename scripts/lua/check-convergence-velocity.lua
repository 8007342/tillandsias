-- @env CARGO_TARGET_DIR
-- @trace spec:observability-convergence, order:2068-cqis
-- @cheatsheet runtime/plan-discipline.md
--
-- check-convergence-velocity.lua — convergence velocity and proximity, or an
-- honest statement that nothing computes them. PORTED from
-- scripts/check-convergence-velocity.sh as the carried shell-to-lua item of
-- 2068-cqis; the history below is the .sh's, kept because the litmus and the
-- no-python-runtime-policy archive note (plan/archive/no-python-runtime-policy-
-- 2026-06-16.md:61) depend on it.
--
-- A RULE THAT ALWAYS PASSES IS NOT A RULE (order 831-ezea). This was backed by
-- a Python checker; under the no-Python runtime policy the Python was retired
-- and the wrapper left printing a no-op WARN and exiting 0, a green lie wearing
-- a guard's name. The retirement note says a Rust replacement "is still
-- desired for real enforcement": the enforcement does not exist. So this
-- emits the one verdict it can honestly compute, "I could not compute this",
-- which is distinct from "I computed this and it is clean".
--
-- GRAMMAR — exactly one verdict line on stdout. The .sh printed
-- `summary: unavailable:<reason>` and exited 0; a Lua decider must end on a
-- house prefix, so (as in the check-cycle-scheduler port) the token is now
-- could-not-run, with the runner's exit code for it:
--   could-not-run:convergence-velocity:no-rust-checker        exit 3
--   could-not-run:convergence-velocity:rust-checker-unwired   exit 3
-- The computed branch, when a Rust checker lands, MUST carry population=<n>
-- (831-ezea); a could-not-run carries none, because the sweep did not look and
-- its denominator is unknown, not zero (the 702-68zj scar).
-- The .sh's third reason, unavailable:no-binary-probe (plan-binary-probe.sh
-- missing), has no counterpart: this probe is in this file.
--
-- THE PROBE. An executable bit is a claim; running the binary is evidence
-- (704-zcgi). The candidate homes are the ones the retirement note names
-- (tillandsias-metrics, tillandsias-logging) and tillandsias-policy, where the
-- other retired checkers landed; each in release then debug, under
-- CARGO_TARGET_DIR (absolute or root-relative) and then target/, .exe first,
-- as resolve_target_binary orders them. A binary counts only when its
-- `capabilities` lists convergence-velocity exactly (a binary predating the
-- subcommand answers --help and still cannot do this).
--
-- THE HALF-MIGRATED STATE: the successor declares the capability but this
-- decider does not call it yet (its output contract was never specified).
-- That is reported as its own reason, never as "no checker" or as clean.

local ROOT = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
if ROOT == "" then ROOT = "." end

local dirs = {}
local ctd = env.get("CARGO_TARGET_DIR") or ""
if ctd ~= "" then
    if ctd:sub(1, 1) == "/" or ctd:match("^%a:") then dirs[#dirs + 1] = ctd
    else dirs[#dirs + 1] = ROOT .. "/" .. ctd end
end
dirs[#dirs + 1] = ROOT .. "/target"

local function declares(bin)
    local ok, r = pcall(proc.run, { argv = { bin, "capabilities" }, timeout_ms = 15000 })
    if not (ok and r and r.ok) then return false end
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if text.trim(l) == "convergence-velocity" then return true end
    end
    return false
end

local checker
for _, name in ipairs({ "tillandsias-metrics", "tillandsias-logging", "tillandsias-policy" }) do
    for _, profile in ipairs({ "release", "debug" }) do
        for _, d in ipairs(dirs) do
            for _, exe in ipairs({ ".exe", "" }) do
                local bin = d .. "/" .. profile .. "/" .. name .. exe
                if not checker and declares(bin) then checker = bin end
            end
        end
    end
end

if not checker then
    verdict.emit("could-not-run:convergence-velocity:no-rust-checker", 3,
        "convergence velocity is unenforced: Python retired, no Rust checker built")
end
verdict.emit("could-not-run:convergence-velocity:rust-checker-unwired", 3,
    checker .. " declares convergence-velocity but this decider does not call it yet")
