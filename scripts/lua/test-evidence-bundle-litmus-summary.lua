-- @trace spec:dev-build, order:1596-ivhr
--
-- test-evidence-bundle-litmus-summary.lua — PORTED from
-- test-evidence-bundle-litmus-summary.sh (1596-ivhr). The evidence bundle's
-- litmus totals come from each phase log's summary lines (`PASS:  <n>` and
-- `FAIL:  <n>`), so a phase whose prose names "FAIL" is not counted as a
-- failure, and a phase that really failed is.
--
--   1 ALL PASS  three phase logs, one with an explanatory FAIL token in its
--               prose: passed=140 failed=0
--   2 FAILURE   a post-build phase with FAIL: 1: passed=134 failed=1
--   3 READERS   the .sh's retired FAIL: line has no reader in scripts/, the
--               gate steps or the litmus specs; the count searched is printed
--
-- Both parser arms ask scripts/generate-evidence-bundle.sh itself, through its
-- --litmus-count-fixture=<log:log:...> mode, as the .sh did.
--
-- Terminal line, unchanged because the litmus expects it byte for byte:
-- ok: evidence bundle litmus summary parser, or
-- refused:evidence-bundle-litmus-summary:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-evidence-bundle-litmus-summary.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/evidence-bundle-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok   " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

-- The parser's answer for the named phase logs.
local function counts(logs)
    local paths = {}
    for _, name in ipairs(logs.order) do
        fs.write(REL .. "/" .. name, logs[name])
        paths[#paths + 1] = S .. "/" .. name
    end
    local r = proc.run({ argv = { "bash", ROOT .. "/scripts/generate-evidence-bundle.sh", "--litmus-count-fixture=" .. table.concat(paths, ":") }, timeout_ms = 60000 })
    return text.trim(r.stdout or ""), (r.status == "exited" and r.code or -1)
end

local got, rc = counts({
    order = { "pre.log", "post.log", "runtime.log" },
    ["pre.log"] = "running pre-build litmus\nPASS:  129\nFAIL:  0\nnote: previous implementation counted this explanatory FAIL token incorrectly\n",
    ["post.log"] = "running post-build litmus\nPASS:  6\nFAIL:  0\n",
    ["runtime.log"] = "running runtime litmus\nPASS:  5\nFAIL:  0\n",
})
if rc == 0 and got == "passed=140 failed=0" then ok("all-pass phases, prose naming FAIL not counted: " .. got)
else bad("all-pass phases: expected \"passed=140 failed=0\", got \"" .. got .. "\" (rc=" .. rc .. ")") end

got, rc = counts({
    order = { "pre.log", "post.log" },
    ["pre.log"] = "PASS:  129\nFAIL:  0\n",
    ["post.log"] = "PASS:  5\nFAIL:  1\n",
})
if rc == 0 and got == "passed=134 failed=1" then ok("a failing phase is counted: " .. got)
else bad("failing phase: expected \"passed=134 failed=1\", got \"" .. got .. "\" (rc=" .. rc .. ")") end

-- 3: the retired FAIL: line, assembled so this file cannot match itself.
local NEEDLE = "FA" .. "IL: expected \"%s\", got"
local SELF = "scripts/lua/test-evidence-bundle-litmus-summary.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and body and has(body, NEEDLE) then hits[#hits + 1] = f end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired FAIL: line has 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired FAIL: line: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok: evidence bundle litmus summary parser", 0) end
verdict.emit("refused:evidence-bundle-litmus-summary:" .. failed, 1)
