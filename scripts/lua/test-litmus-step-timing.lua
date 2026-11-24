-- @trace order:1233-jqp4, order:2239-crf7
--
-- test-litmus-step-timing.lua — the litmus runner's PER-STEP duration records
-- (.cache/metrics/litmus-step-timing.jsonl). A budget is set per step; the
-- per-test records only bound a step from above, which left 17 tests on yoga
-- unsettled. These arms pin that the step records exist, are one per EXECUTED
-- step, are valid JSON, and are never fabricated. The helper is extracted from
-- the runner itself (sed between `_lt_step_record() {` and `}`) so the arms
-- test the shipped code. Ported from test-litmus-step-timing.sh (2239-crf7).
--
--   1 one record per executed step (a real run of binary-signing)
--   2 every record is valid JSON with test/step/budget_ms/duration_ms/exit
--   3 a stubbed clock or a zero start writes no record
--   4 a real clock writes the measured duration
--   5 an unwritable log path changes nothing (rc 0, silent)
--
-- THIS checkout's plan binary is resolved first and handed to the runner
-- explicitly: without it, a regime with no CARGO_TARGET_DIR and no
-- TILLANDSIAS_PLAN_BIN makes the runner refuse to execute steps (1427-utmy).
--
-- Verdict: ok:litmus-step-timing:<n> arms | violation:litmus-step-timing:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local R = root .. "/scripts/run-litmus-test.sh"
local pass, failn = 0, 0
local function ok(m) pass = pass + 1; out.line("ok   " .. m) end
local function bad(m) failn = failn + 1; out.line("FAIL " .. m) end

local rel = "target/plan-scratch/litmus-step-timing-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end
local function count_nonempty(s)
    local n = 0
    for _, l in ipairs(text.lines(s or "")) do if l ~= "" then n = n + 1 end end
    return n
end

if not fs.read("scripts/run-litmus-test.sh"):find("\n_lt_step_record() {", 1, true) then
    cleanup()
    verdict.emit("violation:litmus-step-timing:premise: _lt_step_record not found in scripts/run-litmus-test.sh", 1)
end

local probe = proc.run{ argv = { "bash", "-s" }, cwd = root, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null)" || p=""\ncase "$p" in ./*) p="$PWD/${p#./}" ;; esac\nprintf "%s" "$p"\n' }
local PB = text.trim(probe.stdout or "")

-- 1 + 2: a real run
local log = W .. "/steps.jsonl"
local r = proc.run{ argv = { R, "binary-signing", "--compact" }, cwd = root, timeout_ms = 110000,
    env = { TILLANDSIAS_PLAN_BIN = PB, LITMUS_STEP_TIMING_LOG = log } }
local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[%d;]*m", "")
local steps = 0
for _, l in ipairs(text.lines(o)) do if l:find("%[STEP %d+/%d+%]") then steps = steps + 1 end end
local recs = fs.exists(rel .. "/steps.jsonl") and count_nonempty(fs.read(rel .. "/steps.jsonl")) or 0
if steps < 1 then
    local ls = text.lines(text.trim(o)); bad("premise: the run executed no steps (runner output: " .. (ls[#ls] or "") .. ")")
elseif recs ~= steps then
    bad("one record per executed step: " .. steps .. " steps ran, " .. recs .. " records written")
else
    ok("one record per executed step (" .. steps .. ")")
end
if PB == "" then
    bad("premise: no plan binary to validate the records with")
elseif fs.exists(rel .. "/steps.jsonl") then
    local j = proc.run{ argv = { PB, "json", "get", "-c",
        'select((has("test") and has("step") and has("budget_ms") and has("duration_ms") and has("exit") and (.duration_ms >= 0)) | not)', log },
        timeout_ms = 30000 }
    local badrecs = text.trim((j.stdout or "") .. (j.stderr or ""))
    if j.code ~= 0 then
        bad("json get could not read the records (rc=" .. tostring(j.code) .. "): " .. badrecs:sub(1, 120))
    elseif badrecs ~= "" then
        bad("a record lacks a field or has a negative duration: " .. (text.lines(badrecs)[1] or ""))
    else
        ok("every record (not just the last) is valid JSON with test/step/budget_ms/duration_ms/exit")
    end
end

-- 3-5: the extracted helper under a stubbed clock.
-- rec.sh <runner> <now_ms> <log> <record args...>: prints rc=<n>.
fs.write(rel .. "/rec.sh", table.concat({
    'fn="$(sed -n \'/^_lt_step_record() {/,/^}/p\' "$1")"',
    'eval "$fn"',
    'NOW="$2"; timing_now_ms() { echo "$NOW"; }',
    'LITMUS_STEP_TIMING_LOG="$3"; shift 3',
    '_lt_step_record "$@"; echo "rc=$?"',
}, "\n") .. "\n")
local function rec(now, logp, ...)
    local argv = { "bash", W .. "/rec.sh", R, now, logp, ... }
    local x = proc.run{ argv = argv, timeout_ms = 30000 }
    return text.trim((x.stdout or "") .. (x.stderr or ""))
end

local log2 = W .. "/stub.jsonl"
rec("0", log2, "x.yaml", "1", "3000", "1234", "0")
rec("5000", log2, "x.yaml", "1", "3000", "0", "0")
local s2 = fs.exists(rel .. "/stub.jsonl") and fs.read(rel .. "/stub.jsonl") or ""
if s2 == "" then ok("a stubbed clock or a zero start writes no record")
else bad("a record was fabricated: " .. s2) end

rec("5000", W .. "/real.jsonl", "litmus-x.yaml", "2", "3000", "1234", "7")
local s3 = fs.exists(rel .. "/real.jsonl") and fs.read(rel .. "/real.jsonl") or ""
if s3:find('"test":"litmus-x","step":2,"budget_ms":3000,"duration_ms":3766,"exit":7}', 1, true) then
    ok("a real clock writes the measured duration")
else bad("expected duration 3766 for litmus-x step 2, got: " .. s3) end

local o4 = rec("5000", "/proc/nonexistent/x.jsonl", "x.yaml", "1", "3000", "1234", "0")
if o4 == "rc=0" then ok("an unwritable log path changes nothing (rc 0, silent)")
else bad("unwritable log path leaked: " .. o4) end

cleanup()
if failn == 0 then verdict.ok("litmus-step-timing:" .. pass .. " arms") end
verdict.emit("violation:litmus-step-timing:" .. failn .. " failed", 1)
