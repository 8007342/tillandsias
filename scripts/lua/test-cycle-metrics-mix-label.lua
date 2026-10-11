-- @trace order:890-nkdz, order:1105-h8vr, order:1592-idmu
--
-- test-cycle-metrics-mix-label.lua — PORTED from test-cycle-metrics-mix-label.sh
-- (1592-idmu's carried shell->lua item). ORDER 890-nkdz, rule 1 (FORCED-ONLY
-- for cross-host gate timings): the `timing:` line must carry
-- `build_check_mix=mixed:forced=N,memoised=M` whenever the contributing log
-- holds ANY memoised gate run, and NO such label only when every run was
-- forced. The mean must exclude memoised records in both. This leg was RED
-- against the pre-890 reporter and green after.
--
--   1 MIXED   a mixed log is labelled and its mean excludes the memoised run
--   2 FORCED  a forced-only log carries no label, mean 65000
--   3 READERS the .sh's retired terminal lines (PASS:/FAIL: build_check_mix
--             label ...) have no reader in scripts/, the gate steps or the
--             litmus specs; the count of files searched is printed
--
-- ORDER 1105-h8vr — A FIXTURE THAT RAN NO ARMS MUST NOT REPORT PASS. The two
-- reporter arms feed DIFFERENT scratch logs, so one cycle-metrics.sh run
-- cannot produce both readings; collapsing them would drop an arm and still
-- read green. The arm count is pinned: anything but EXPECTED_ARMS refuses.
--
-- Terminal line: ok:cycle-metrics-mix-label-fixture:<n> or
-- refused:cycle-metrics-mix-label-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-metrics-mix-label.lua

local EXPECTED_ARMS = 3
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/cycle-metrics-mix-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok   " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

-- The `timing:` line cycle-metrics.sh prints for a timing log holding `records`.
local function timing(name, records)
    fs.write(REL .. "/" .. name, records)
    local r = proc.run({ argv = { "bash", "scripts/cycle-metrics.sh", "--no-repo-scan", "--no-experts" },
        env = { TILLANDSIAS_TIMING_LOG = ROOT .. "/" .. REL .. "/" .. name }, timeout_ms = 120000 })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:sub(1, 7) == "timing:" then return l end
    end
    return ""
end
local function labels(line)
    local t = {}
    for kv in line:gmatch("build_check_[%a_]+=[^ ]+") do t[#t + 1] = kv end
    return table.concat(t, " ")
end

local line = timing("mixed.jsonl", '{"step":"build-check","duration_ms":64000,"phase":"check"}\n{"step":"build-check-memoized","duration_ms":400,"phase":"check"}\n{"step":"build-check","duration_ms":66000,"phase":"check"}\n')
if has(line, "build_check_ms_avg=65000 build_check_mix=mixed:forced=2,memoised=1 ") then
    ok("mixed log: labelled, mean excludes the memoised run (" .. labels(line) .. ")")
else
    bad("mixed log: expected label mixed:forced=2,memoised=1 and mean 65000; got: " .. (line ~= "" and line or "<no timing line>"))
end

line = timing("forced.jsonl", '{"step":"build-check","duration_ms":64000,"phase":"check"}\n{"step":"build-check","duration_ms":66000,"phase":"check"}\n')
if has(line, "build_check_mix=") then
    bad("forced-only log must carry no label; got: " .. line)
elseif has(line, "build_check_ms_avg=65000 ") then
    ok("forced-only log: no label, mean 65000")
else
    bad("forced-only log: unexpected line: " .. (line ~= "" and line or "<no timing line>"))
end

-- 3: the retired terminal lines, assembled so this file cannot match itself.
local NEEDLES = { "PA" .. "SS: build_check_mix label", "FA" .. "IL: build_check_mix label" }
local SELF = "scripts/lua/test-cycle-metrics-mix-label.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and body then
                for _, n in ipairs(NEEDLES) do
                    if has(body, n) then hits[#hits + 1] = f; break end
                end
            end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired PASS:/FAIL: terminal lines have 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired terminal lines: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL } })
local total = passed + failed
if total ~= EXPECTED_ARMS then
    verdict.emit("refused:cycle-metrics-mix-label-fixture:arms-ran:" .. total .. "/" .. EXPECTED_ARMS, 1,
        "an arm stopped executing; a dropped arm is not a pass (1105-h8vr)")
end
if failed == 0 then verdict.emit("ok:cycle-metrics-mix-label-fixture:" .. passed, 0) end
verdict.emit("refused:cycle-metrics-mix-label-fixture:" .. failed, 1)
