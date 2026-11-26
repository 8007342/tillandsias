-- @trace order:1500-gu5r, order:2205-cepb, spec:ci-release
-- @env TILLANDSIAS_TEST_CHECK
-- @env FORGE_SPEC_INDEX_DIR
-- @env FORGE_SPEC_INDEX_ROOT
-- @env PROJECT_ROOT
-- @env XDG_CACHE_HOME
--
-- test-groundtruth-regime-fails-closed.lua — PORTED from
-- test-groundtruth-regime-fails-closed.sh (2205-cepb), same arms, same lines.
-- check-groundtruth-regime-invariance grades its sets CONCURRENTLY
-- (1500-gu5r), and one of those grades can be killed or crash on a loaded
-- host. The check must then FAIL CLOSED naming the set and regime, never
-- compare the survivors and print ok. A fake plan binary (TILLANDSIAS_PLAN_BIN)
-- delegates to the real one except where an arm tells it to misbehave:
--   1 CONTROL: every grade completes -> ok:groundtruth-regime-invariant
--   2 one grade (a set, one regime) is KILLED after printing some verdicts ->
--     unavailable:grade-incomplete:<set>:<regime>, exit 2, nothing compared
--   3 one grade COMPLETES with a failing case (grade exits non-zero, as it does
--     for any FAIL) -> read as a divergence, NOT as an incomplete grade: the
--     check keys on the summary line, never on grade's exit status
-- Pre-fix: arm 2 FAILS (the killed grade became an empty verdict list and the
-- check printed ok). TILLANDSIAS_TEST_CHECK overrides the check (mutation).
--
-- Verdict: ok:groundtruth-regime-fails-closed:<n> after the .sh's
-- `PASS: groundtruth-regime-fails-closed <n>/<n>` line (the litmus reads it),
-- or `FAIL: ...` then violation:groundtruth-regime-fails-closed:<n>.

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local CHECK = env.get("TILLANDSIAS_TEST_CHECK") or (root .. "/scripts/check-groundtruth-regime-invariance.sh")
local rel = "target/plan-scratch/gt-fails-closed-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

-- The real plan binary, resolved as the .sh did (a script FILE, not a string).
fs.write(rel .. "/resolve.sh", '. scripts/plan-binary-probe.sh && resolve_plan_binary\n')
local r = proc.run{ argv = { "bash", W .. "/resolve.sh" } }
local REAL = text.trim(r.stdout or "")
if not r.ok or REAL == "" then
    cleanup()
    log.raw("FAIL: no runnable plan binary")
    verdict.emit("violation:groundtruth-regime-fails-closed:no-plan-binary", 1)
end
if REAL:sub(1, 1) ~= "/" and not REAL:match("^%a:[/\\]") then REAL = root .. "/" .. REAL:gsub("^%./", "") end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

-- The fake: GT_MODE=kill|failcase, GT_SET=<basename>, GT_REGIME=live|dead.
-- The dead regime is recognised by EXACTLY the check's closed-port endpoint.
fs.write(rel .. "/plan", ([[#!/usr/bin/env bash
if [ "${1:-}" = grade ] && [ -n "${GT_MODE:-}" ] && [ "$(basename "${2:-}")" = "${GT_SET:-}" ]; then
    regime=live
    [ "${TILLANDSIAS_INFERENCE_ENDPOINT:-}" = "http://127.0.0.1:1" ] && regime=dead
    if [ "$regime" = "${GT_REGIME:-}" ]; then
        case "$GT_MODE" in
            kill)
                "@REAL@" grade "$2" | grep -E '^(PASS|FAIL)' | head -n 1
                kill -9 $$ ;;
            failcase)
                "@REAL@" grade "$2" | awk '!d && /^PASS / { sub(/^PASS /, "FAIL "); d = 1 } { sub(/ fail=0 /, " fail=1 "); print }'
                exit 1 ;;
        esac
    fi
fi
exec "@REAL@" "$@"
]]):gsub("@REAL@", function() return REAL end))
proc.run{ argv = { "chmod", "+x", W .. "/plan" } }

-- The first set in `ls` order (byte order under the runner's C locale).
local sets = {}
for _, l in ipairs(text.lines(proc.run{ argv = { "find", "openspec/litmus-tests/groundtruth",
        "-maxdepth", "1", "-name", "*.yaml" } }.stdout or "")) do
    sets[#sets + 1] = l:match("([^/]+)$")
end
table.sort(sets)
local SET = sets[1]

local function run(extra)
    -- The LIVE regime is the ambient env, as in the .sh. The endpoint
    -- variables are TILLANDSIAS_* and pass through the runner; the other
    -- names grade reads (spec index, cache) are scrubbed, so forward them,
    -- or live would grade from a different index than the caller's (2168-634p).
    local e = { TILLANDSIAS_PLAN_BIN = W .. "/plan" }
    for _, k in ipairs({ "FORGE_SPEC_INDEX_DIR", "FORGE_SPEC_INDEX_ROOT", "PROJECT_ROOT", "XDG_CACHE_HOME" }) do
        local v = env.get(k)
        if v then e[k] = v end
    end
    for k, v in pairs(extra) do e[k] = v end
    local p = proc.run{ argv = { "bash", CHECK, "--strict" }, env = e, timeout_ms = 600000 }
    return text.trim(p.stdout or ""), p.code
end

local o, rc = run({})
if o:match("^ok:groundtruth%-regime%-invariant:") then
    if rc == 0 then ok("1: CONTROL: every grade completes -> " .. o) else bad("1: rc=" .. rc .. " [" .. o .. "]") end
else bad("1: control answered [" .. o .. "] rc=" .. tostring(rc)) end

o, rc = run({ GT_MODE = "kill", GT_SET = SET, GT_REGIME = "dead" })
if o == "unavailable:grade-incomplete:" .. SET .. ":dead" and rc == 2 then
    ok("2: a killed dead-regime grade of " .. SET .. " fails closed by name (exit 2)")
else
    bad("2: a killed grade answered [" .. o .. "] rc=" .. tostring(rc) ..
        " (want unavailable:grade-incomplete:" .. SET .. ":dead, exit 2)")
end

o, rc = run({ GT_MODE = "failcase", GT_SET = SET, GT_REGIME = "live" })
if o:match("^violation:groundtruth%-regime%-dependent:") then
    ok("3: a completed grade with a failing case reads as a divergence, not as incomplete (" .. o .. ")")
else bad("3: a completed failing grade answered [" .. o .. "] rc=" .. tostring(rc)) end

cleanup()
local total = pass + fail
if fail == 0 then
    out.line("PASS: groundtruth-regime-fails-closed " .. pass .. "/" .. total)
    verdict.emit("ok:groundtruth-regime-fails-closed:" .. pass, 0)
end
out.line("FAIL: groundtruth-regime-fails-closed " .. pass .. "/" .. total)
verdict.emit("violation:groundtruth-regime-fails-closed:" .. fail, 1)
