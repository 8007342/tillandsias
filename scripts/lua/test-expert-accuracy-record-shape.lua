-- @trace order:2282-peuy, order:917-6iwv
--
-- test-expert-accuracy-record-shape.lua — the negative controls of
-- record-expert-accuracy.sh. A repeat of "rate=100%" beside "expert answered
-- nothing" is a regression (911-m7js): a number that cannot tell "answered
-- correctly" from "was never asked" is worse than none.
--   1 nothing graded is a null rate, never 0 and never 100
--   2 a partial run at 100% carries status, denominator and unexercised engines
--   3 a fully graded run says so, graded == total
--   4 the estimated rate is null, never inferred from the validated one
--   5 a fixture-sourced record is labelled source=fixture
--   6 the record names a resolved host
-- The grader line is supplied through the subject's own seam: a stale index-dir
-- override does NOT force a skip (lenovinha 2026-09-04, still graded 33/33).
--
-- Verdict: ok:test-expert-accuracy-record-shape:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("test-expert-accuracy-record-shape")
local REC = "scripts/record-expert-accuracy.sh"
if not pcall(fs.read, REC) then T:refuse("script-missing", REC) end

local function record(line)
    local r = T:run{ fixture.posix_shell(), REC, "--dry-run", cwd = fixture.repo_root(),
        env = { TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE = line } }
    local body = text.trim(r.stdout or "")
    local good, rec = pcall(json.parse, body)
    return body, good and type(rec) == "table" and rec or {}
end
-- The record's own bytes are read: a key absent and a key that is null differ.
local function has(body, ...)
    local flat = body:gsub("%s", "")
    for _, want in ipairs({ ... }) do
        local at = flat:find(want, 1, true)
        if not at or not flat:sub(at + #want, at + #want):find("^[,}]") then return false end
    end
    return true
end
local FULL = "groundtruth-result: sets=4 total=33 pass=31 fail=2 skipped=0 elapsed_ms=6322"

local b = record("groundtruth-result: sets=4 total=33 pass=0 fail=0 skipped=33 skipped_engines=spec.answer elapsed_ms=12")
T:arm("1 never-called renders a null rate, not 0 and not 100",
    has(b, '"status":"never-called"', '"graded":0', '"validated_rate_pct":null'), b)
b = record("groundtruth-result: sets=4 total=33 pass=28 fail=0 skipped=5 skipped_engines=spec.answer elapsed_ms=2664")
T:arm("2 a partial run carries status, denominator and the unexercised engine",
    has(b, '"status":"partial"', '"graded":28', '"total":33', '"skipped":5', '"skipped_engines":["spec.answer"]', '"validated_rate_pct":100'), b)
local rec
b, rec = record(FULL)
T:arm("3 a fully graded run reports status=graded with graded==total",
    has(b, '"status":"graded"', '"graded":33', '"total":33', '"skipped":0', '"validated_rate_pct":93'), b)
T:arm("4 estimated accuracy is null", has(b, '"estimated_rate_pct":null'), b)
T:arm("5 a fixture-sourced record is labelled", has(b, '"source":"fixture"'), b)
T:arm("6 the record names a resolved host",
    type(rec.host) == "string" and rec.host ~= "" and rec.host ~= "unknown", rec.host)
T:finish()
