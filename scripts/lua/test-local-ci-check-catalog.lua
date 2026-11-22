-- @trace order:2223-bzsn, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-local-ci-check-catalog.lua — pins scripts/lua/local-ci-check-catalog.lua
-- (2223-bzsn). Expectations are written
-- out by hand, so the fixture keeps its meaning after the bash case tables it
-- replaced are gone. At port time the lookups were also compared with those
-- tables for all sixteen ids and three unknown ones (recorded on the PR).
--
--   1 the helper prints sixteen catalog rows then the default row `*`, four tab-separated fields each
--   2 a known id's row gives its weight, spec ref and reason
--   3 the default row `*`: weight 0, spec:unknown, "Check failed: %s"
--   4 every catalog weight is a positive integer and every id is unique
--
-- Verdict: ok:local-ci-check-catalog:4 arms | violation:local-ci-check-catalog:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/local-ci-check-catalog-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", root .. "/" .. rel } }
local function cleanup() proc.run{ argv = { "find", root .. "/" .. rel, "-delete" }, timeout_ms = 60000 } end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", root .. "/" .. rel .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("local-ci-check-catalog:no-runner") end

-- 1 the rows
local r = proc.run{ argv = { RUNNER, "script", "run", "--helper", root .. "/scripts/lua/local-ci-check-catalog.lua" }, timeout_ms = 60000 }
local rows = {}
for _, l in ipairs(text.lines(r.stdout or "")) do
    if l ~= "" then
        local id, w, s, why = l:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
        rows[#rows + 1] = { id = id, w = w, s = s, why = why, line = l }
    end
end
local shape = r.code == 0 and #rows == 17
for _, row in ipairs(rows) do if not row.id then shape = false end end
if shape and rows[17].id == "*" then ok("1 sixteen catalog rows then the default row, four fields each")
else bad("1 rc=" .. tostring(r.code) .. " rows=" .. tostring(#rows)) end

-- 2 / 3 the rows themselves. local-ci.sh no longer looks ids up in bash: the
-- convergence writer (local-ci-convergence-artifacts.lua, 2224-x32n) reads
-- these rows, and its own fixture pins the id substituted into `%s`.
local function row_text(id)
    for _, row in ipairs(rows) do
        if row.id == id then return row.w .. "|" .. row.s .. "|" .. row.why end
    end
    return "(absent)"
end
local got = row_text("rust-clippy-all-features")
local want = "180|spec:dev-build|All-features clippy warnings: run 'cargo clippy --workspace --all-targets --all-features -- -D warnings' (see /tmp/clippy-all-features-check.log)"
if got == want then ok("2 a known id's row gives its weight, spec ref and reason")
else bad("2 got [" .. got .. "]") end

got = row_text("*")
if got == "0|spec:unknown|Check failed: %s" then ok("3 the default row: 0, spec:unknown, and a reason with %s where the id goes")
else bad("3 got [" .. got .. "]") end

-- 4 weights and uniqueness
local seen, good = {}, #rows == 17
for i = 1, 16 do
    local row = rows[i] or {}
    if not row.id or seen[row.id] or not (row.w or ""):match("^[1-9]%d*$") then good = false end
    if row.id then seen[row.id] = true end
end
if good then ok("4 every catalog weight is a positive integer and every id is unique")
else bad("4 a duplicate id or a non-positive weight") end

cleanup()
if failn == 0 then verdict.ok("local-ci-check-catalog:4 arms") end
verdict.emit("violation:local-ci-check-catalog:" .. failn .. " failed", 1)
