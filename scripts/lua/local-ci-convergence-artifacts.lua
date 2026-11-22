-- @trace order:2224-x32n, spec:ci-release
--
-- local-ci-convergence-artifacts.lua — local-ci.sh to Lua, slice 4
-- (2224-x32n): write_convergence_artifacts. From one local-ci run it writes
-- three files:
--   <dir>/centicolon-signature.jsonl  one record appended per run
--   <dir>/centicolon-delta.json       the whole history plus the latest record
--   <dir>/evidence-bundle.json        hashes and counts tying the run together
--
-- The score (earned / denominator / residual / regime) still comes from
-- `tillandsias-plan score-checks` (977-j6qu), never from arithmetic here, and
-- an unavailable or refusing scorer is still a refusal, never a fallback.
--
-- INTERFACE CHANGE, named (coordinator ruling 2026-11-22): json.encode sorts
-- keys, so the records written from here have their keys in byte order where
-- the jq writer kept insertion order. The values are the same. No reader
-- depends on the order: update-convergence-dashboard.sh reads by key,
-- tillandsias-headless matches file names only, and signature_hash is a hash
-- of the whole file, which nothing recomputes per line or chains.
--
-- KNOWN BUG CARRIED ON PURPOSE (row 2226): max_residual_reason is read from
-- failed_checks[i] with the index of the catalog-ordered failure list, as the
-- bash writer did, so this slice's parity evidence stays pure. Its fix is its
-- own PR.
--
-- SECOND KNOWN BUG CARRIED (row 2227): the bash writer set `trap ... RETURN`
-- to delete its temp files, then SOURCED plan-binary-probe.sh. A RETURN trap
-- also fires when a sourced file finishes, so the file of residual reasons was
-- deleted before it was read and top_residual_reasons was always []. This
-- writer still builds the list and writes [] while CARRY_EMPTY_TOP_RESIDUAL
-- is set; the fix PR drops the flag.
--
-- Usage: script run scripts/lua/local-ci-convergence-artifacts.lua
--          -- --input <repo-relative file> --plan-bin <path>
-- The input file has one NAME=value per line; a list item is NAME[]=value.
-- Scalars: DIR (repo-relative), CHECK_LOG_INDEX (any path), REPO_ROOT,
-- CHECKS_PASSED, CHECKS_FAILED, TESTS_RUN, TESTS_PASSED, TESTS_FAILED,
-- TESTS_SKIPPED, CI_TIMESTAMP, VERSION_VALUE, SOURCE_COMMIT, CI_RUN_ID,
-- CI_PHASE. Lists: CHECK_IDS, FAILED_CHECKS, FAILED_REASONS.
--
-- Verdict: ok:local-ci-convergence-artifacts:records=<n> residual=<cc>
--        | blocked:local-ci:no-plan-binary | blocked:local-ci:scorer-refused

local input, plan_bin
local i = 1
while arg[i] do
    if arg[i] == "--input" then input = arg[i + 1]; i = i + 2
    elseif arg[i] == "--plan-bin" then plan_bin = arg[i + 1]; i = i + 2
    else error("local-ci-convergence-artifacts: unknown argument '" .. arg[i] .. "'") end
end
if not input then error("local-ci-convergence-artifacts: --input is required") end

local S, L = {}, { CHECK_IDS = {}, FAILED_CHECKS = {}, FAILED_REASONS = {} }
for _, line in ipairs(text.lines(fs.read(input))) do
    local name, value = line:match("^([A-Z_]+)%[%]=(.*)$")
    if name then
        L[name] = L[name] or {}
        L[name][#L[name] + 1] = value
    else
        name, value = line:match("^([A-Z_]+)=(.*)$")
        if name then S[name] = value end
    end
end
local function int(name) return math.tointeger(tonumber(S[name] or "") or 0) or 0 end

if (plan_bin or "") == "" then
    verdict.emit("blocked:local-ci:no-plan-binary — the centicolon scorer lives in tillandsias-plan (977-j6qu); refusing to compute a second score here", 1)
end

-- the catalog (slice 3), by id, with its default row
local catalog, default = {}, nil
for _, row in ipairs(text.lines(proc.run{
    argv = { plan_bin or "", "script", "run", "--helper", "scripts/lua/local-ci-check-catalog.lua" },
    timeout_ms = 60000 }.stdout or "")) do
    local id, w, spec, why = row:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if id then
        local r = { w = math.tointeger(tonumber(w)) or 0, spec = spec, why = why }
        if id == "*" then default = r else catalog[id] = r end
    end
end
default = default or { w = 0, spec = "spec:unknown", why = "Check failed: %s" }
local function entry(id) return catalog[id] or default end
local function weight(id) return entry(id).w end
local function spec_ref(id) return entry(id).spec end
local function reason(id) return (entry(id).why:gsub("%%s", function() return id end)) end


local CARRY_EMPTY_TOP_RESIDUAL = true -- row 2227
local failed = {}
for _, id in ipairs(L.FAILED_CHECKS) do failed[id] = true end

local failed_specs, failed_weights, top = {}, {}, {}
local score_in = {}
for _, id in ipairs(L.CHECK_IDS) do
    local w = weight(id)
    if failed[id] then
        failed_specs[#failed_specs + 1] = spec_ref(id)
        failed_weights[#failed_weights + 1] = w
        top[#top + 1] = { spec_or_obligation_id = spec_ref(id), reason = reason(id), cc = w }
    end
    score_in[#score_in + 1] = id .. " " .. tostring(w) .. " " .. (failed[id] and "fail" or "pass") .. "\n"
end

local sc = proc.run{ argv = { plan_bin, "score-checks" }, stdin = table.concat(score_in), timeout_ms = 120000 }
local ok_parse, score = pcall(json.parse, sc.stdout or "")
if sc.code ~= 0 or not ok_parse or type(score) ~= "table" then
    log.raw(sc.stderr or "")
    verdict.emit("blocked:local-ci:scorer-refused (rc=" .. tostring(sc.code) .. ") — see the score-checks verdict above", 1)
end
local total_cc, passed_cc, residual_cc = score.denominator, score.earned, score.residual
if score.regime ~= "monotone" then
    log.raw("note:local-ci:centicolon-regime:" .. tostring(score.regime) .. " — this score is NOT comparable with the previous run")
end


-- carried as-is: index i of the catalog-ordered list into FAILED_CHECKS (2226)
local max_spec, max_reason, max_cc = "n/a", "n/a", 0
if #failed_specs > 0 then
    max_spec, max_reason, max_cc = failed_specs[1], reason(L.FAILED_CHECKS[1]), failed_weights[1]
    for k = 1, #failed_specs do
        if failed_weights[k] > max_cc then
            max_spec, max_reason, max_cc = failed_specs[k], reason(L.FAILED_CHECKS[k] or ""), failed_weights[k]
        end
    end
end

local function percent(earned, total)
    if total <= 0 then return 0 end
    local p = (earned / total) * 100
    return math.tointeger(p) or p
end
local function count_lines(s) local _, n = s:gsub("\n", ""); return n end

local dir = S.DIR
pcall(fs.mkdir, dir)
local jsonl, delta, bundle = dir .. "/centicolon-signature.jsonl", dir .. "/centicolon-delta.json", dir .. "/evidence-bundle.json"

local record = {
    timestamp = S.CI_TIMESTAMP, version = S.VERSION_VALUE, source_commit = S.SOURCE_COMMIT,
    source_namespace = "local_development", ci_run_id = S.CI_RUN_ID, ci_phase = S.CI_PHASE,
    release_date = S.CI_TIMESTAMP,
    expected_total_cc = total_cc, actual_earned_cc = passed_cc, residual_cc = residual_cc,
    percent_closed = percent(passed_cc, total_cc),
    litmus_tests_run = int("TESTS_RUN"), litmus_passed = int("TESTS_PASSED"),
    litmus_failed = int("TESTS_FAILED"), litmus_skipped = int("TESTS_SKIPPED"),
    project_cc_earned = passed_cc, project_cc_total = total_cc,
    ci_result = int("CHECKS_FAILED") == 0 and "PASS" or "FAIL",
    max_residual_spec = max_spec, max_residual_reason = max_reason, max_residual_cc = max_cc,
    evidence_bundle_ref = "target/convergence/evidence-bundle.json",
    centicolon_projection_ref = "target/convergence/centicolon-dashboard.md",
    -- carried as-is (row 2227): the bash writer always wrote [] here; see the header
    top_residual_reasons = json.array(CARRY_EMPTY_TOP_RESIDUAL and {} or top),
    failed_checks = json.array(L.FAILED_CHECKS),
    failed_reasons = json.array(L.FAILED_REASONS),
}
local prior = fs.exists(jsonl) and fs.read(jsonl) or ""
local all = prior .. json.encode(record) .. "\n"
fs.write(jsonl, all)
local signature_hash = hash.sha256(all)
local records = count_lines(all)

local history = {}
for _, l in ipairs(text.lines(all)) do
    if l ~= "" then history[#history + 1] = json.parse(l) end
end
local delta_text = json.encode({
    generated_at = S.CI_TIMESTAMP, source_file = "target/convergence/centicolon-signature.jsonl",
    record_count = records, signature_hash = signature_hash,
    latest = history[#history] or json.null, history = json.array(history),
}) .. "\n"
fs.write(delta, delta_text)

local check_log_hash, check_log_records = "n/a", 0
local idx = S.CHECK_LOG_INDEX or ""
if idx ~= "" then
    local r = proc.run{ argv = { "cat", idx }, timeout_ms = 60000 }
    if r.code == 0 then
        check_log_hash = hash.sha256(r.stdout or "")
        check_log_records = count_lines(r.stdout or "")
    end
end
local root = S.REPO_ROOT or ""
local idx_ref = idx
if root ~= "" and idx:sub(1, #root + 1) == root .. "/" then idx_ref = idx:sub(#root + 2) end

fs.write(bundle, json.encode({
    generated_at = S.CI_TIMESTAMP, version = S.VERSION_VALUE, source_commit = S.SOURCE_COMMIT,
    source_namespace = "local_development", ci_phase = S.CI_PHASE, ci_run_id = S.CI_RUN_ID,
    signature_hash = signature_hash, delta_hash = hash.sha256(delta_text),
    check_log_index_ref = idx_ref, check_log_index_hash = check_log_hash,
    centicolon_dashboard_hash = "n/a",
    signature_records = records, delta_records = 1, check_log_records = check_log_records,
    project_cc_total = total_cc, project_cc_earned = passed_cc, residual_cc = residual_cc,
    check_count = #L.CHECK_IDS,
}) .. "\n")

verdict.ok("local-ci-convergence-artifacts:records=" .. records .. " residual=" .. tostring(residual_cc))
