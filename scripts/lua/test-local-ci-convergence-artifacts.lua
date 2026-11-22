-- @trace order:2224-x32n, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-local-ci-convergence-artifacts.lua — pins
-- scripts/lua/local-ci-convergence-artifacts.lua, local-ci.sh's convergence
-- writer (2224-x32n). Expectations are written out by hand from the catalog
-- weights (rust-formatting 40, rust-clippy 60, rust-tests 80, litmus-tests
-- 140, an unknown id 0: denominator 320), so the fixture keeps its meaning
-- after the bash writer it replaced is gone. At port time the writer was also
-- compared with that bash writer, value for value, over four runs (recorded
-- on the PR).
--
--   1 one failure: the record's score, result, failure list and heaviest residual
--   2 a second run appends: the earlier line is kept byte for byte, and the delta holds both
--   3 the evidence bundle's hashes are the sha256 of the files it names, and its counts match
--   4 every check passing: PASS, residual 0, no residual spec, percent_closed the integer 100
--   5 no plan binary: blocked, a non-zero exit, and no signature file written
--   6 several failures: the heaviest is the reported residual, not the first
--   7 failures out of catalog order: the heaviest residual carries its own reason (2226-63ta)
--   8 a failing run lists its failures in top_residual_reasons (2227-rqgw)
--
-- Verdict: ok:local-ci-convergence-artifacts-fixture:8 arms
--        | violation:local-ci-convergence-artifacts-fixture:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/local-ci-convergence-artifacts-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", root .. "/" .. rel } }
local function cleanup() proc.run{ argv = { "find", root .. "/" .. rel, "-delete" }, timeout_ms = 60000 } end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", root .. "/" .. rel .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("local-ci-convergence-artifacts-fixture:no-runner") end

local IDX = root .. "/" .. rel .. "/check-log.jsonl"
fs.write(rel .. "/check-log.jsonl", "{\"a\":1}\n{\"b\":2}\n")

local function run(name, failed, plan_bin)
    local dir = rel .. "/" .. name
    local lines = {
        "DIR=" .. dir, "REPO_ROOT=" .. root, "CHECK_LOG_INDEX=" .. IDX,
        "CHECKS_PASSED=" .. (5 - #failed), "CHECKS_FAILED=" .. #failed,
        "TESTS_RUN=7", "TESTS_PASSED=5", "TESTS_FAILED=1", "TESTS_SKIPPED=1",
        "CI_TIMESTAMP=2026-11-22T00:00:00Z", "VERSION_VALUE=0.5.1", "SOURCE_COMMIT=abc",
        "CI_RUN_ID=run-" .. name, "CI_PHASE=pre-build",
    }
    for _, id in ipairs({ "rust-formatting", "rust-clippy", "rust-tests", "litmus-tests", "mystery" }) do
        lines[#lines + 1] = "CHECK_IDS[]=" .. id
    end
    for _, id in ipairs(failed) do
        lines[#lines + 1] = "FAILED_CHECKS[]=" .. id
        lines[#lines + 1] = "FAILED_REASONS[]=" .. id .. " red"
    end
    fs.write(rel .. "/" .. name .. ".in", table.concat(lines, "\n") .. "\n")
    local r = proc.run{ argv = { RUNNER, "script", "run", root .. "/scripts/lua/local-ci-convergence-artifacts.lua",
        "--", "--input", rel .. "/" .. name .. ".in", "--plan-bin", plan_bin or RUNNER }, timeout_ms = 120000 }
    return r, dir
end
local function lines_of(path)
    local t = {}
    for _, l in ipairs(text.lines(fs.read(path))) do if l ~= "" then t[#t + 1] = l end end
    return t
end

-- 1 one failure
local r, dir = run("one", { "rust-tests" })
local rec = (r.code == 0 and fs.exists(dir .. "/centicolon-signature.jsonl"))
    and json.parse(lines_of(dir .. "/centicolon-signature.jsonl")[1]) or {}
if rec.project_cc_total == 320 and rec.project_cc_earned == 240 and rec.residual_cc == 80
    and rec.percent_closed == 75 and rec.ci_result == "FAIL"
    and #(rec.failed_checks or {}) == 1 and rec.failed_checks[1] == "rust-tests"
    and rec.failed_reasons[1] == "rust-tests red"
    and rec.max_residual_spec == "spec:testing" and rec.max_residual_cc == 80
    and (rec.max_residual_reason or ""):find("Test failures detected", 1, true)
    and rec.litmus_tests_run == 7 and rec.ci_run_id == "run-one" then
    ok("1 one failure: score 240 of 320, residual 80, FAIL, and rust-tests is the heaviest residual")
else bad("1 rc=" .. tostring(r.code) .. " record=" .. json.encode(rec)) end

-- 2 a second run appends
local first = lines_of(dir .. "/centicolon-signature.jsonl")[1] or ""
local r2 = run("one", { "rust-clippy" })
local all = lines_of(dir .. "/centicolon-signature.jsonl")
local delta = fs.exists(dir .. "/centicolon-delta.json") and json.parse(fs.read(dir .. "/centicolon-delta.json")) or {}
if r2.code == 0 and #all == 2 and all[1] == first and delta.record_count == 2
    and #(delta.history or {}) == 2 and (delta.latest or {}).max_residual_spec == "spec:dev-build" then
    ok("2 a second run appends one line, keeps the first byte for byte, and the delta holds both")
else bad("2 rc=" .. tostring(r2.code) .. " lines=" .. #all .. " record_count=" .. tostring(delta.record_count)) end

-- 3 the evidence bundle
local b = fs.exists(dir .. "/evidence-bundle.json") and json.parse(fs.read(dir .. "/evidence-bundle.json")) or {}
if b.signature_hash == hash.sha256(fs.read(dir .. "/centicolon-signature.jsonl"))
    and b.delta_hash == hash.sha256(fs.read(dir .. "/centicolon-delta.json"))
    and b.check_log_index_hash == hash.sha256(fs.read(rel .. "/check-log.jsonl"))
    and b.check_log_index_ref == rel .. "/check-log.jsonl"
    and b.signature_records == 2 and b.check_log_records == 2 and b.check_count == 5 and b.delta_records == 1 then
    ok("3 the bundle's hashes are the sha256 of the files it names, and its counts match")
else bad("3 bundle=" .. json.encode(b)) end

-- 4 every check passing
local r4, dir4 = run("pass", {})
local rec4 = (r4.code == 0 and fs.exists(dir4 .. "/centicolon-signature.jsonl"))
    and json.parse(lines_of(dir4 .. "/centicolon-signature.jsonl")[1]) or {}
local raw4 = fs.exists(dir4 .. "/centicolon-signature.jsonl") and fs.read(dir4 .. "/centicolon-signature.jsonl") or ""
if rec4.ci_result == "PASS" and rec4.residual_cc == 0 and rec4.max_residual_spec == "n/a"
    and rec4.max_residual_cc == 0 and raw4:find("\"percent_closed\":100[,}]") then
    ok("4 every check passing: PASS, residual 0, no residual spec, percent_closed written as 100")
else bad("4 rc=" .. tostring(r4.code) .. " " .. raw4) end

-- 5 no plan binary
local r5, dir5 = run("noplan", { "rust-tests" }, "")
local said = (r5.stdout or "") .. (r5.stderr or "")
if r5.code ~= 0 and said:find("blocked:local-ci:no-plan-binary", 1, true)
    and not fs.exists(dir5 .. "/centicolon-signature.jsonl") then
    ok("5 no plan binary: blocked by name, a non-zero exit, no signature written")
else bad("5 rc=" .. tostring(r5.code) .. " " .. said) end

-- 6 several failures: the heaviest is reported, not the first. Failure order
-- equals catalog order here, so the carried indexing bug (row 2226) is not
-- in play; that row's own arm differs the two orders.
local r6, dir6 = run("many", { "rust-formatting", "litmus-tests" })
local rec6 = (r6.code == 0 and fs.exists(dir6 .. "/centicolon-signature.jsonl"))
    and json.parse(lines_of(dir6 .. "/centicolon-signature.jsonl")[1]) or {}
if rec6.max_residual_spec == "spec:litmus-convergence" and rec6.max_residual_cc == 140
    and (rec6.max_residual_reason or ""):find("Litmus test failures detected", 1, true)
    and rec6.residual_cc == 180 then
    ok("6 several failures: the heaviest (litmus-tests, 140) is the reported residual")
else bad("6 rc=" .. tostring(r6.code) .. " record=" .. json.encode(rec6)) end

-- 7 (2226-63ta) failure order differs from catalog order: litmus-tests failed
-- before rust-tests, but the catalog lists rust-tests first. The heaviest
-- residual's reason must be litmus-tests' own, not rust-tests'.
local r7, dir7 = run("order", { "litmus-tests", "rust-tests" })
local rec7 = (r7.code == 0 and fs.exists(dir7 .. "/centicolon-signature.jsonl"))
    and json.parse(lines_of(dir7 .. "/centicolon-signature.jsonl")[1]) or {}
if rec7.max_residual_spec == "spec:litmus-convergence" and rec7.max_residual_cc == 140
    and (rec7.max_residual_reason or ""):find("Litmus test failures detected", 1, true) then
    ok("7 failures out of catalog order: the heaviest residual carries its own reason (2226)")
else bad("7 spec=" .. tostring(rec7.max_residual_spec) .. " reason=" .. tostring(rec7.max_residual_reason)) end

-- 8 (2227-rqgw) a failing run lists its failures in top_residual_reasons
local r8, dir8 = run("top", { "rust-tests" })
local rec8 = (r8.code == 0 and fs.exists(dir8 .. "/centicolon-signature.jsonl"))
    and json.parse(lines_of(dir8 .. "/centicolon-signature.jsonl")[1]) or {}
local top8 = rec8.top_residual_reasons or {}
if #top8 == 1 and top8[1].spec_or_obligation_id == "spec:testing" and top8[1].cc == 80
    and (top8[1].reason or ""):find("Test failures detected", 1, true) then
    ok("8 a failing run lists its failure in top_residual_reasons (2227)")
else bad("8 top_residual_reasons=" .. json.encode(top8)) end

cleanup()
if failn == 0 then verdict.ok("local-ci-convergence-artifacts-fixture:8 arms") end
verdict.emit("violation:local-ci-convergence-artifacts-fixture:" .. failn .. " failed", 1)
