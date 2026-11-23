-- @trace order:2186-niam, order:831-ezea, order:911-m7js, order:923-ws3r, order:965-sxec, order:1074-96z9
-- @env TILLANDSIAS_HOST_KIND TILLANDSIAS_HOST_ID HOSTNAME CARGO_TARGET_DIR
--
-- check-archiver-ready-set.lua — the plan archiver's ready-set check as a
-- STEP_LUA gate step (2186-niam). It was an inline build.sh block, which could
-- not be pooled or input-scoped. The plain step format cannot express its two
-- special rules, so they live here, in Lua rather than a new .sh, so the shell
-- ratchet does not move:
--
--   1. THE MEMO (911-m7js) and its HIT/MISS TIMING (1074-96z9). The check is
--      ledger-bound (16-105 s), and its inputs are the ledger plus the
--      archiver, so scripts/archiver-check-memo.sh memoises the verdict on a
--      digest of them. A hit and a miss each emit one timing record
--      (archiver-check-hit / archiver-check-miss, phase=check) so the hit rate
--      stays computable. The cost of the work is still measured: the gate's
--      `_run` wraps this whole step, as it wrapped the inline miss.
--   2. THE FORGE-ONLY EXIT-3 SKIP (965-sxec, 923-ws3r). Exit 3 means the
--      instrument could not run, never a ledger verdict. It is skipped (loudly)
--      only inside a forge AND only for the one tokenised cause,
--      could-not-run:no-usable-ruby. Any other exit 3 (a stale plan binary,
--      an unreadable fragment) is refused, because it is repairable where it hit.
--
-- proc.run starts from a cleared env. PATH, HOME, TMPDIR and TILLANDSIAS_*
-- pass through (so TILLANDSIAS_PLAN_BIN and TILLANDSIAS_ARCHIVER_* reach the
-- archiver); CARGO_TARGET_DIR is forwarded by hand.
--
-- Verdicts:
--   ok:archiver-ready-set:memo-hit                       exit 0
--   ok:archiver-ready-set:checked                        exit 0
--   skip:archiver-ready-set:no-usable-ruby-in-forge      exit 0
--   could-not-run:archiver-ready-set:instrument-exit-3   exit 1
--   violation:archiver-ready-set:exit-<rc>               exit 1

local child_env = {}
local ctd = env.get("CARGO_TARGET_DIR")
if ctd and ctd ~= "" then child_env.CARGO_TARGET_DIR = ctd end

local function run(argv, timeout_ms)
    return proc.run({ argv = argv, env = child_env, timeout_ms = timeout_ms })
end

local function rc_of(res)
    if res.status == "exited" and res.code then return res.code end
    return 1
end

-- timing-log.sh's host chain: TILLANDSIAS_HOST_ID, HOSTNAME, `hostname`,
-- with whitespace stripped, else "unknown".
local function host_name()
    for _, k in ipairs({ "TILLANDSIAS_HOST_ID", "HOSTNAME" }) do
        local v = env.get(k)
        if v and v ~= "" then
            v = v:gsub("%s", "")
            if v ~= "" then return v end
        end
    end
    local h = run({ "hostname" }, 5000)
    if h.status == "exited" and h.ok then
        local v = h.stdout:gsub("%s", "")
        if v ~= "" then return v end
    end
    return "unknown"
end

-- Best effort, like timing_emit: a timing failure never changes the verdict.
local function emit_timing(step, t0, rc)
    local dur = time.now_ms() - t0
    if dur < 0 then dur = 0 end
    if dur >= 86400000 then return end
    pcall(run, { "bash", "scripts/cycle-metrics.sh", "--emit-timing",
        "step=" .. step, "phase=check", "duration_ms=" .. math.floor(dur),
        "exit=" .. rc, "host=" .. host_name() }, 30000)
end

local t0 = time.now_ms()

local memo = run({ "bash", "scripts/archiver-check-memo.sh", "check" }, 60000)
if memo.status == "exited" and memo.ok then
    log.raw(text.trim(memo.stdout) .. " — ledger and archiver unchanged since the last pass; check not re-run")
    emit_timing("archiver-check-hit", t0, 0)
    verdict.emit("ok:archiver-ready-set:memo-hit", 0)
end

local res = run({ "bash", "scripts/archive-plan-packets.sh", "--check" }, 900000)
local out = (res.stdout or "") .. (res.stderr or "")
if out ~= "" then log.raw((out:gsub("\n$", ""))) end
local rc = rc_of(res)
if rc == 0 then
    run({ "bash", "scripts/archiver-check-memo.sh", "record" }, 60000)
end
emit_timing("archiver-check-miss", t0, rc)

if rc == 0 then
    verdict.emit("ok:archiver-ready-set:checked", 0)
end

if rc == 3 then
    if env.get("TILLANDSIAS_HOST_KIND") == "forge"
        and out:find("could-not-run:no-usable-ruby", 1, true) then
        log.raw("SKIPPED the plan archiver check: no usable ruby in this forge (965-sxec). The ready set was NOT verified on this run — the archiver's ruby worker never executed. This is not a statement about the ledger.")
        verdict.emit("skip:archiver-ready-set:no-usable-ruby-in-forge", 0)
    end
    log.raw("the plan archiver's check COULD NOT RUN (exit 3) — this says nothing about the ready set; the instrument is what needs repair (923-ws3r)")
    verdict.emit("could-not-run:archiver-ready-set:instrument-exit-3", 1)
end

log.raw("the plan archiver would CHANGE THE READY SET, orphan events, or leave archived rows unanswerable — do not sweep")
verdict.emit("violation:archiver-ready-set:exit-" .. rc, 1)
