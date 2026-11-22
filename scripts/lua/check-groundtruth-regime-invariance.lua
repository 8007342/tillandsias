-- preflight: gate-only-decider — its live regime synthesises one answer per run (plan-current-direction-bootstrap-question, ~4 s on lenovinha 2026-09-30, 0.1 s with inference down); capping synthesis would blind it to rendering flips (1518-8p5k)
-- @trace order:928-qm8k, order:920-pxg6, order:764-p9w7, order:1500-gu5r, order:2220-gtri
-- @env TILLANDSIAS_GROUNDTRUTH_DIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @env FORGE_SPEC_INDEX_DIR FORGE_SPEC_INDEX_ROOT PROJECT_ROOT XDG_CACHE_HOME
--
-- check-groundtruth-regime-invariance.lua — would this case grade differently
-- on a host whose inference is up? PORTED from the .sh (2220-gtri): same
-- grammar, same exit codes, same concurrency, same fail-closed rule.
--
-- THE DEFECT (928-qm8k). A groundtruth case that asserts on ANSWER PROSE has a
-- verdict that depends on the host's synthesis regime. Measured on yoga
-- 2026-08-29: with inference live the Direction query rendered as prose, with
-- it dead as the raw section, so `answer_contains: "## Direction"` passed on
-- retrieval-only hosts and failed on synthesising ones (three hosts red in 24
-- hours). The tell is an assertion that would break if the answer got BETTER.
--
-- NOT A PROSE BAN. Of 18 prose-asserting cases, exactly one varied with the
-- regime; the other 17 assert deterministic renderer output. So the property
-- is INVARIANCE: grade the corpus under both regimes and refuse when a VERDICT
-- moves. Answers may be worded differently; pass/fail must not change.
--
-- GRAMMAR (exactly one line):
--   ok:groundtruth-regime-invariant:<n>-cases                     exit 0
--   violation:groundtruth-regime-dependent:<csv-of-case-ids>      exit 1 with --strict, else 0
--   unavailable:<reason>                                          exit 2
--
-- THE DEAD REGIME points every inference/embedding endpoint at a closed port.
-- Not "unset": unset can fall back to a reachable default, which would make
-- the two runs one regime and the check vacuous.
--
-- CONCURRENT GRADES, ORDERED COMPARISON (1500-gu5r). Every set is graded live
-- and dead at once (proc.spawn), then compared in set order, so the verdict
-- and its wording do not depend on finishing order. FAIL CLOSED on an
-- incomplete grade: each must print its `groundtruth-result:` summary line
-- (grade's exit status is its FAIL count, so it cannot tell "two cases failed"
-- from a harness error); a killed or crashed grade is unavailable:, never a
-- set that silently counted zero cases.
--
-- THE RUNNER SCRUBS FORGE_SPEC_INDEX_DIR, FORGE_SPEC_INDEX_ROOT, PROJECT_ROOT
-- and XDG_CACHE_HOME (2168-634p). The .sh's grades inherited them, so they are
-- forwarded to both regimes; otherwise the live grade would read a different
-- spec index than the caller's. TILLANDSIAS_* endpoints pass through.
--
-- Seams: TILLANDSIAS_GROUNDTRUTH_DIR; TILLANDSIAS_PLAN_BIN names the binary
-- that GRADES (a fixture's fake), else the runner that runs this script.

local STRICT = false
for i = 1, #arg do if arg[i] == "--strict" then STRICT = true end end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if ROOT == "" then verdict.emit("unavailable:no-repo-root", 2) end

local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or "" end
if PLAN ~= "" and PLAN:sub(1, 1) ~= "/" then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
if PLAN == "" or proc.run({ argv = { "test", "-x", PLAN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.emit("unavailable:no-runnable-plan-binary", 2)
end

local G = env.get("TILLANDSIAS_GROUNDTRUTH_DIR") or (ROOT .. "/openspec/litmus-tests/groundtruth")
local ls = proc.run({ argv = { "find", G, "-maxdepth", "1", "-name", "*.yaml", "-type", "f" }, timeout_ms = 30000 })
if ls.status ~= "exited" or ls.code ~= 0 then verdict.emit("unavailable:groundtruth-dir-unreadable", 2) end
local sets = {}
for l in (ls.stdout or ""):gmatch("[^\n]+") do sets[#sets + 1] = l end
table.sort(sets) -- the .sh's glob order (C locale byte order)

local function base_env()
    local e = {}
    for _, k in ipairs({ "FORGE_SPEC_INDEX_DIR", "FORGE_SPEC_INDEX_ROOT", "PROJECT_ROOT", "XDG_CACHE_HOME" }) do
        local v = env.get(k)
        if v then e[k] = v end
    end
    return e
end
local function dead_env()
    local e = base_env()
    e.TILLANDSIAS_INFERENCE_ENDPOINT = "http://127.0.0.1:1"
    e.TILLANDSIAS_EMBED_ENDPOINT = "http://127.0.0.1:1/v1"
    e.TILLANDSIAS_SPEC_EXPERT_ENDPOINT = "http://127.0.0.1:1/v1"
    return e
end

-- Launch every grade, then collect in order.
local handles = {}
for i, s in ipairs(sets) do
    handles[i] = {
        live = proc.spawn({ argv = { PLAN, "grade", s }, env = base_env(), timeout_ms = 600000 }),
        dead = proc.spawn({ argv = { PLAN, "grade", s }, env = dead_env(), timeout_ms = 600000 }),
    }
end
local results = {}
for i = 1, #sets do
    results[i] = { live = handles[i].live:wait().stdout or "", dead = handles[i].dead:wait().stdout or "" }
end

local function basename(p) return p:match("[^/]+$") end
for i, s in ipairs(sets) do
    for _, regime in ipairs({ "live", "dead" }) do
        if not results[i][regime]:find("\ngroundtruth%-result: ") and not results[i][regime]:find("^groundtruth%-result: ") then
            log.raw("[check-groundtruth-regime-invariance] the " .. regime .. " grade of " .. basename(s)
                .. " did not run to completion (no groundtruth-result line): it was killed, crashed or refused its input, so this check cannot vouch for that set in that regime. Nothing was compared.\n")
            verdict.emit("unavailable:grade-incomplete:" .. basename(s) .. ":" .. regime, 2)
        end
    end
end

-- "<VERDICT> <case>" for every PASS/FAIL line, as a set.
local function verdicts(raw)
    local t = {}
    for l in raw:gmatch("[^\n]+") do
        -- the .sh: grep '^(PASS|FAIL)' | awk '{print $1" "$2}'
        if l:find("^PASS") or l:find("^FAIL") then
            local f1, f2 = l:match("^(%S+)%s*(%S*)")
            t[#t + 1] = f1 .. " " .. f2
        end
    end
    table.sort(t)
    return t
end

local total, diverged, seen = 0, {}, {}
for i = 1, #sets do
    local live, dead = verdicts(results[i].live), verdicts(results[i].dead)
    total = total + #live
    local in_live, in_dead = {}, {}
    for _, v in ipairs(live) do in_live[v] = true end
    for _, v in ipairs(dead) do in_dead[v] = true end
    -- comm -3: lines in exactly one side; the case id is the last field.
    local moved = {}
    for _, v in ipairs(live) do if not in_dead[v] then moved[#moved + 1] = v:match("(%S+)$") end end
    for _, v in ipairs(dead) do if not in_live[v] then moved[#moved + 1] = v:match("(%S+)$") end end
    table.sort(moved)
    for _, c in ipairs(moved) do
        if not seen[i .. "\0" .. c] then
            seen[i .. "\0" .. c] = true
            diverged[#diverged + 1] = c
        end
    end
end

if total == 0 then verdict.emit("unavailable:no-cases-graded", 2) end
if #diverged > 0 then
    log.raw("[check-groundtruth-regime-invariance] These cases grade DIFFERENTLY with inference up vs down, so their verdict is a property of the HOST rather than of the answer. The tell is an assertion that would break if the answer got BETTER — replace prose assertions with substance ones (confidence, citation kind/count, grading-time span_contains), which read the same on every host.\n")
    verdict.emit("violation:groundtruth-regime-dependent:" .. table.concat(diverged, ","), STRICT and 1 or 0)
end
verdict.emit("ok:groundtruth-regime-invariant:" .. total .. "-cases", 0)
