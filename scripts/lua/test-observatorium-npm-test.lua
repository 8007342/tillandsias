-- @trace order:2066-obsv, spec:observatorium-dashboard
--
-- test-observatorium-npm-test.lua — the observatorium's own test suite in the
-- gate (task 3.6 of openspec/changes/observatorium-static-html).
--
-- WHY. The static site generator, the honesty lint that fails the build
-- closed, and the manual publish/verify tools (site/publish.mjs, verify.mjs)
-- are pinned only by `cd observatorium && npm test`, and nothing ran it: a
-- change to observatorium/ could land with the suite red. This step runs it on
-- every ./build.sh --check.
--
-- WHAT RUNS. The `test` script of observatorium/package.json, read from the
-- file so the gate and `npm test` cannot drift. It must be
-- `node --test <pattern>...`; the patterns are handed to node unexpanded and
-- node (>= 22, the package's engines floor) globs them itself, so the same
-- files run without npm or a POSIX shell (npm is npm.cmd on msys). The tap
-- reporter is forced so the counts are parseable.
--
-- ARMS:
--   1 REAL     the suite passes here, with at least one test and no failure
--   2 CONTROL  a scratch suite of one passing and one failing test, run the
--              same way, exits non-zero and reports exactly pass 1 fail 1: a
--              failing test reds this step, and the patterns are globbed
--
-- Grammar (one line on stdout; arms and node's output on stderr/stdout):
--   ok:observatorium-npm-test:<n> tests                              exit 0
--   violation:observatorium-npm-test:<arm>                           exit 1
--   could-not-run:observatorium-npm-test                             exit 3
--     (no node >= 22 on PATH; the step nominates STEP_SKIP_EXIT=3)

local NAME = "observatorium-npm-test"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local v = proc.run({ argv = { "node", "--version" }, timeout_ms = 30000 })
local major = v.status == "exited" and v.code == 0 and tonumber((v.stdout or ""):match("^v(%d+)%.")) or nil
if not major then
    verdict.could_not_run(NAME, "no node on PATH")
end
if major < 22 then
    verdict.could_not_run(NAME, "node " .. text.trim(v.stdout or "") .. " is below the observatorium's engines floor (>=22)")
end

local PKG = "observatorium/package.json"
if not fs.exists(PKG) then
    verdict.emit("violation:" .. NAME .. ":no-package-json", 1, PKG .. " does not exist")
end
local ok_pkg, pkg = pcall(json.parse, fs.read(PKG) or "")
local script = ok_pkg and type(pkg) == "table" and type(pkg.scripts) == "table" and pkg.scripts.test or nil
if type(script) ~= "string" or not text.starts_with(script, "node --test ") then
    verdict.emit("violation:" .. NAME .. ":test-script-shape", 1,
        PKG .. " scripts.test is not `node --test <pattern>...` (got " .. tostring(script) .. "); update this step with it")
end
local patterns = {}
for p in script:sub(#"node --test " + 1):gmatch("%S+") do patterns[#patterns + 1] = p end

-- Run `node --test` over patterns in cwd; returns code, tests, pass, fail, stdout.
local function suite(cwd, pats)
    local argv = { "node", "--test", "--test-reporter=tap" }
    for _, p in ipairs(pats) do argv[#argv + 1] = p end
    local r = proc.run({ argv = argv, cwd = cwd, timeout_ms = 300000 })
    local outp = r.stdout or ""
    local code = r.status == "exited" and r.code or -1
    return code, tonumber(outp:match("\n# tests (%d+)")), tonumber(outp:match("\n# pass (%d+)")),
        tonumber(outp:match("\n# fail (%d+)")), outp
end

local failed = {}
local function arm(name, cond, got)
    if cond then log.raw("ok:   " .. name) else
        log.raw("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local code, tests, pass, fail, outp = suite(ROOT .. "/observatorium", patterns)
local real_ok = code == 0 and (tests or 0) > 0 and fail == 0 and pass == tests
arm("1 REAL the observatorium suite passes", real_ok,
    "rc=" .. code .. " tests=" .. tostring(tests) .. " pass=" .. tostring(pass) .. " fail=" .. tostring(fail))
if not real_ok then
    local lines = text.lines(outp)
    for i = math.max(1, #lines - 60), #lines do log.raw("  | " .. lines[i]) end
end

local REL = "target/plan-scratch/observatorium-npm-test-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
fs.write(REL .. "/pass.test.mjs", "import test from 'node:test';\ntest('passes', () => {});\n")
fs.write(REL .. "/fail.test.mjs", "import test from 'node:test';\nimport assert from 'node:assert/strict';\ntest('fails', () => { assert.equal(1, 2); });\n")
local c2, t2, p2, f2 = suite(ROOT .. "/" .. REL, { "*.test.mjs" })
arm("2 CONTROL a failing test reds the run and the pattern is globbed", c2 ~= 0 and t2 == 2 and p2 == 1 and f2 == 1,
    "rc=" .. c2 .. " tests=" .. tostring(t2) .. " pass=" .. tostring(p2) .. " fail=" .. tostring(f2))

if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. table.concat(failed, ","):gsub(" ", "-"):sub(1, 60), 1)
end
verdict.ok(NAME, tests .. " tests")
